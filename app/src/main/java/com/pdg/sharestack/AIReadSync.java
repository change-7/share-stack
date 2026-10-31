package com.pdg.sharestack;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.UUID;

final class AIReadSync implements MacBridgeClient.ReceiveControl {
    static final String INTENTS = "intents";
    private final Context context;
    private volatile boolean stopped, obsolete;
    private volatile HttpURLConnection active;
    private volatile AIReadIntent running;

    AIReadSync(Context context) { this.context = context.getApplicationContext(); }
    static SharedPreferences preferences(Context context) { return context.getSharedPreferences("ai_read_sync", 0); }

    private static ArrayList<AIReadIntent> load(Context context) {
        try {
            JSONArray data = new JSONArray(preferences(context).getString(INTENTS, "[]"));
            ArrayList<AIReadIntent> result = new ArrayList<>();
            for (int i = 0; i < data.length(); i++) {
                JSONObject row = data.getJSONObject(i);
                AIReadIntent intent = new AIReadIntent(row.getString("id"), row.getString("itemID"), row.getString("peerPin"));
                intent.revision = row.getLong("revision");
                intent.changedAt = row.getLong("changedAt");
                intent.allowed = row.getBoolean("allowed");
                intent.phase = AIReadIntent.Phase.valueOf(row.getString("phase"));
                intent.progress = row.optInt("progress");
                intent.error = row.optString("error");
                result.add(intent);
            }
            return result;
        } catch (org.json.JSONException | IllegalArgumentException error) {
            throw new IllegalStateException("AI 읽기 동기화 기록을 읽을 수 없습니다", error);
        }
    }

    private static void save(Context context, ArrayList<AIReadIntent> intents) {
        try {
            JSONArray rows = new JSONArray();
            for (AIReadIntent intent : intents) rows.put(new JSONObject().put("id", intent.id).put("itemID", intent.itemID)
                .put("peerPin", intent.peerPin).put("revision", intent.revision).put("changedAt", intent.changedAt)
                .put("allowed", intent.allowed).put("phase", intent.phase.name()).put("progress", intent.progress).put("error", intent.error));
            if (!preferences(context).edit().putString(INTENTS, rows.toString()).commit()) {
                throw new IllegalStateException("AI 읽기 동기화 기록을 저장하지 못했습니다");
            }
        } catch (org.json.JSONException error) { throw new IllegalStateException(error); }
    }

    static synchronized AIReadIntent get(Context context, String itemID) {
        String pin = MacBridgeClient.savedPairing(context).certificatePin;
        for (AIReadIntent intent : load(context)) if (intent.itemID.equals(itemID) && intent.peerPin.equals(pin)) return intent;
        return null;
    }

    static synchronized void choose(Context context, String itemID, boolean allowed) throws IOException {
        MacBridgeClient.Pairing pairing = MacBridgeClient.savedPairing(context);
        if (!MacBridgeClient.isValidPairing(pairing)) throw new IOException("먼저 Mac 연결에서 QR로 기기를 연결하세요");
        ArrayList<AIReadIntent> intents = load(context);
        AIReadIntent intent = null;
        for (AIReadIntent candidate : intents) {
            if (candidate.itemID.equals(itemID) && candidate.peerPin.equals(pairing.certificatePin)) intent = candidate;
        }
        if (intent == null) {
            intent = new AIReadIntent(UUID.randomUUID().toString(), itemID, pairing.certificatePin);
            intents.add(intent);
        }
        intent.choose(allowed, System.currentTimeMillis());
        save(context, intents);
    }

    static synchronized ArrayList<AIReadIntent> pending(Context context) {
        String pin = MacBridgeClient.savedPairing(context).certificatePin;
        ArrayList<AIReadIntent> result = new ArrayList<>();
        for (AIReadIntent intent : load(context)) if (intent.pending() && intent.peerPin.equals(pin)) result.add(intent);
        result.sort(Comparator.comparing(intent -> intent.allowed));
        return result;
    }

    private static synchronized boolean current(Context context, AIReadIntent request) {
        AIReadIntent latest = get(context, request.itemID);
        return latest != null && latest.id.equals(request.id) && latest.revision == request.revision;
    }

    private static synchronized void update(Context context, AIReadIntent request, AIReadIntent.Phase phase, int progress, String error) {
        ArrayList<AIReadIntent> intents = load(context);
        for (AIReadIntent intent : intents) if (intent.id.equals(request.id)) {
            if (intent.phase == phase && intent.progress == progress && intent.error.equals(error)) return;
            if (intent.update(request.revision, phase, progress, error)) save(context, intents);
            return;
        }
    }

    private static synchronized void acknowledge(Context context, AIReadIntent request, JSONObject response) throws Exception {
        if (!request.id.equals(response.getString("id"))) throw new IOException("Mac AI 읽기 확인 ID가 일치하지 않습니다");
        ArrayList<AIReadIntent> intents = load(context);
        for (AIReadIntent intent : intents) if (intent.id.equals(request.id)) {
            if (!current(context, request)) return;
            if (!intent.acknowledge(response.getLong("revision"), response.getBoolean("allowed"), response.getBoolean("ready"))) {
                throw new IOException("Mac의 AI 읽기 허용이 아직 확인되지 않았습니다. Mac의 AI 읽기 설정을 확인하세요");
            }
            save(context, intents);
            return;
        }
    }

    void cancelStale() {
        AIReadIntent request = running;
        if (request != null && !current(context, request)) {
            obsolete = true;
            HttpURLConnection connection = active;
            if (connection != null) connection.disconnect();
        }
    }

    void stop() {
        stopped = true;
        HttpURLConnection connection = active;
        if (connection != null) connection.disconnect();
    }

    void runOnce() {
        for (AIReadIntent request : pending(context)) {
            if (stopped) return;
            if (!request.graceElapsed(System.currentTimeMillis())) continue;
            running = request;
            obsolete = false;
            if (!current(context, request)) continue;
            try {
                MacBridgeClient.Pairing pairing = MacBridgeClient.validate(context, MacBridgeClient.savedPairing(context));
                if (!request.peerPin.equals(pairing.certificatePin)) continue;
                JSONObject uploaded = null;
                if (request.allowed) {
                    StackItem source = null;
                    for (StackItem item : StackStore.load(context)) if (item.id.equals(request.itemID)) source = item;
                    if (source == null) {
                        choose(context, request.itemID, false);
                        continue;
                    }
                    update(context, request, AIReadIntent.Phase.TRANSFERRING, 1, "");
                    uploaded = MacBridgeClient.upload(context, pairing, source, this);
                }
                if (cancelled() || !current(context, request)) continue;
                JSONObject response = MacBridgeClient.syncAIRead(pairing, request, uploaded, this);
                acknowledge(context, request, response);
            } catch (Exception error) {
                if (!stopped) update(context, request, AIReadIntent.Phase.FAILED, 0,
                    error.getMessage() == null ? "Mac 연결 실패" : error.getMessage());
            } finally { active = null; running = null; }
        }
    }

    @Override public boolean cancelled() { return stopped || obsolete; }
    @Override public void connection(HttpURLConnection connection) {
        active = connection;
        if (cancelled()) connection.disconnect();
    }
    @Override public void progress(MacBridgeClient.PendingItem item, long offset) {}
    @Override public void uploadProgress(StackItem item, long offset, long size) {
        AIReadIntent request = running;
        if (request != null) update(context, request, AIReadIntent.Phase.TRANSFERRING,
            size == 0 ? 95 : Math.min(95, (int) (offset * 95 / size)), "");
    }
}
