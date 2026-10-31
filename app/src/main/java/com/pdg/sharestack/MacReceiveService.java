package com.pdg.sharestack;

import android.app.*;
import android.content.*;
import android.os.*;
import java.net.HttpURLConnection;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.*;

public final class MacReceiveService extends Service implements MacBridgeClient.ReceiveControl {
    private static final String STOP = "stop";
    private static final String SELECTED = "selected";
    private static final String SYNC_AI = "sync_ai";
    private static final String CHECK_ON_OPEN = "check_on_open";
    private boolean checkingOnOpen;
    private final ScheduledExecutorService aiWorker = Executors.newSingleThreadScheduledExecutor();
    private AIReadSync aiSync;
    private ScheduledFuture<?> aiPoll;
    private final ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile boolean stopped;
    private volatile HttpURLConnection active;
    private ScheduledFuture<?> poll;
    private ScheduledFuture<?> sendPoll;
    private final Set<String> scheduledIDs = new HashSet<>();
    private PowerManager.WakeLock wakeLock, aiWakeLock;
    private long lastProgress;
    private int jobs;

    static void start(Context context, ArrayList<String> ids) {
        Intent intent = new Intent(context, MacReceiveService.class);
        if (ids != null) intent.putStringArrayListExtra(SELECTED, ids);
        context.startForegroundService(intent);
    }

    static void checkOnOpen(Context context) {
        if (!MacBridgeClient.isValidPairing(MacBridgeClient.savedPairing(context))) return;
        context.startForegroundService(new Intent(context, MacReceiveService.class).setAction(CHECK_ON_OPEN));
    }

    static void syncAI(Context context) {
        context.startForegroundService(new Intent(context, MacReceiveService.class).setAction(SYNC_AI));
    }

    private final SharedPreferences.OnSharedPreferenceChangeListener aiListener = (preferences, key) -> {
        if (AIReadSync.INTENTS.equals(key) && aiSync != null) aiSync.cancelStale();
    };

    static void stop(Context context) {
        context.getSharedPreferences(StackStore.PREFS, 0).edit().putBoolean(MacBridgeClient.AUTO_RECEIVE, false)
            .putBoolean(MacBridgeClient.AUTO_SEND, false)
            .putString(MacBridgeClient.RECEIVE_STATUS, "자동 공유 중지됨").apply();
        context.stopService(new Intent(context, MacReceiveService.class));
    }

    private boolean automatic() {
        return getSharedPreferences(StackStore.PREFS, 0).getBoolean(MacBridgeClient.AUTO_RECEIVE, false);
    }

    private boolean autoSend() {
        return getSharedPreferences(StackStore.PREFS, 0).getBoolean(MacBridgeClient.AUTO_SEND, false);
    }

    @Override public void onCreate() {
        super.onCreate();
        aiSync = new AIReadSync(this);
        AIReadSync.preferences(this).registerOnSharedPreferenceChangeListener(aiListener);
        getSystemService(NotificationManager.class).createNotificationChannel(
            new NotificationChannel("mac_receive", "Mac 파일 수신", NotificationManager.IMPORTANCE_LOW));
        wakeLock = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sharestack:receive");
        wakeLock.setReferenceCounted(false);
        aiWakeLock = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sharestack:ai-sync");
        aiWakeLock.setReferenceCounted(false);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) { stop(this); return START_NOT_STICKY; }
        startForeground(1002, notification("Mac 연결 확인 중"));
        aiSync.cancelStale();
        if (aiPoll == null && !AIReadSync.pending(this).isEmpty()) {
            aiPoll = aiWorker.scheduleWithFixedDelay(this::syncAIOnce, 0, 15, TimeUnit.SECONDS);
        }
        if (intent != null && SYNC_AI.equals(intent.getAction())) {
            aiWorker.schedule(this::syncAIOnce, 700, TimeUnit.MILLISECONDS);
        }
        ArrayList<String> ids = intent == null ? null : intent.getStringArrayListExtra(SELECTED);
        if (ids != null) {
            ArrayList<String> unique = new ArrayList<>();
            for (String id : ids) if (scheduledIDs.add(id)) unique.add(id);
            if (!unique.isEmpty()) {
                jobs++;
                worker.execute(() -> {
                    receive(unique);
                    main.post(() -> { scheduledIDs.removeAll(unique); jobs--; finishIfIdle(); });
                });
            }
        }
        if (intent != null && CHECK_ON_OPEN.equals(intent.getAction()) && !automatic() && !checkingOnOpen) {
            checkingOnOpen = true;
            jobs++;
            worker.execute(() -> {
                receive(null);
                main.post(() -> { checkingOnOpen = false; jobs--; finishIfIdle(); });
            });
        }
        updatePolling();
        finishIfIdle();
        return automatic() || autoSend() || !AIReadSync.pending(this).isEmpty() ? START_STICKY : START_NOT_STICKY;
    }

    private void updatePolling() {
        if (automatic() && poll == null) {
            poll = worker.scheduleWithFixedDelay(() -> receive(null), 0, 15, TimeUnit.SECONDS);
        } else if (!automatic() && poll != null) {
            poll.cancel(false);
            poll = null;
        }
        if (autoSend() && sendPoll == null) {
            sendPoll = worker.scheduleWithFixedDelay(this::sendPending, 0, 15, TimeUnit.SECONDS);
        } else if (!autoSend() && sendPoll != null) {
            sendPoll.cancel(false);
            sendPoll = null;
        }
    }

    private void sendPending() {
        if (stopped || !autoSend()) return;
        MacBridgeClient.Pairing pairing = MacBridgeClient.savedPairing(this);
        if (!MacBridgeClient.isValidPairing(pairing)) return;
        for (StackItem item : StackStore.pendingAutoSend(this, pairing)) {
            if (stopped || !autoSend()) return;
            MacBridgeClient.Pairing current = MacBridgeClient.savedPairing(this);
            if (!pairing.host.equals(current.host) || !pairing.certificatePin.equals(current.certificatePin)
                || !pairing.token.equals(current.token)) return;
            try {
                synchronized (wakeLock) { if (!wakeLock.isHeld()) wakeLock.acquire(10 * 60 * 1000L); }
                try {
                    MacBridgeClient.upload(this, MacBridgeClient.validate(this, pairing), item, this);
                } finally {
                    synchronized (wakeLock) { if (wakeLock.isHeld()) wakeLock.release(); }
                }
                StackStore.finishAutoSend(this, pairing, item.id);
                status("자동 전송 완료: " + item.name);
            } catch (Exception error) {
                if (!stopped) status("자동 전송 대기: " + error.getMessage());
                return;
            }
        }
    }

    private void finishIfIdle() {
        if (AIReadSync.pending(this).isEmpty() && aiPoll != null) { aiPoll.cancel(false); aiPoll = null; }
        if (!automatic() && !autoSend() && jobs == 0 && AIReadSync.pending(this).isEmpty()) stopSelf();
    }

    private void syncAIOnce() {
        if (stopped) return;
        synchronized (aiWakeLock) { if (!aiWakeLock.isHeld()) aiWakeLock.acquire(10 * 60 * 1000L); }
        try { aiSync.runOnce(); }
        finally {
            synchronized (aiWakeLock) { if (aiWakeLock.isHeld()) aiWakeLock.release(); }
            main.post(this::finishIfIdle);
        }
    }

    private void receive(ArrayList<String> ids) {
        if (stopped) return;
        try {
            int count = MacBridgeClient.receive(this, MacBridgeClient.savedPairing(this), ids, this);
            status(count > 0 ? count + "개 수신 완료" : automatic() ? "자동 수신 대기" : "수신 완료");
        } catch (Exception error) {
            if (!stopped) status("수신 실패: " + error.getMessage());
        } finally {
            active = null;
            synchronized (wakeLock) { if (wakeLock.isHeld()) wakeLock.release(); }
        }
    }

    private Notification notification(String text) {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop = PendingIntent.getService(this, 0, new Intent(this, MacReceiveService.class).setAction(STOP), PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, "mac_receive").setSmallIcon(R.drawable.ic_stat_stack)
            .setContentTitle("Share Stack · Mac 연결").setContentText(text).setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).addAction(new Notification.Action.Builder(null, "중지", stop).build()).build();
    }

    private void status(String text) {
        if (stopped) return;
        getSharedPreferences(StackStore.PREFS, 0).edit().putString(MacBridgeClient.RECEIVE_STATUS, text).apply();
        getSystemService(NotificationManager.class).notify(1002, notification(text));
    }

    @Override public boolean cancelled() { return stopped; }
    @Override public void connection(HttpURLConnection connection) {
        active = connection;
        if (stopped) connection.disconnect();
    }
    @Override public void progress(MacBridgeClient.PendingItem item, long offset) {
        synchronized (wakeLock) {
            if (stopped) return;
            if (!wakeLock.isHeld()) wakeLock.acquire(10 * 60 * 1000L);
        }
        long now = SystemClock.elapsedRealtime();
        if (now - lastProgress > 1000) {
            lastProgress = now;
            status(item.name + " · " + (item.size == 0 ? 100 : offset * 100 / item.size) + "%");
        }
    }
    @Override public void onDestroy() {
        stopped = true;
        AIReadSync.preferences(this).unregisterOnSharedPreferenceChangeListener(aiListener);
        aiSync.stop();
        synchronized (aiWakeLock) { if (aiWakeLock.isHeld()) aiWakeLock.release(); }
        if (aiPoll != null) aiPoll.cancel(false);
        aiWorker.shutdownNow();
        if (poll != null) { poll.cancel(false); poll = null; }
        if (sendPoll != null) { sendPoll.cancel(false); sendPoll = null; }
        if (active != null) active.disconnect();
        worker.shutdownNow();
        synchronized (wakeLock) { if (wakeLock.isHeld()) wakeLock.release(); }
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
