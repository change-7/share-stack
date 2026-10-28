package com.pdg.sharestack;

import android.app.*;
import android.content.*;
import android.os.*;
import java.net.HttpURLConnection;
import java.util.ArrayList;
import java.util.concurrent.*;

public final class MacReceiveService extends Service implements MacBridgeClient.ReceiveControl {
    private static final String STOP = "stop";
    private static final String SELECTED = "selected";
    private final ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile boolean stopped;
    private volatile HttpURLConnection active;
    private ScheduledFuture<?> poll;
    private PowerManager.WakeLock wakeLock;
    private long lastProgress;
    private int jobs;

    static void start(Context context, ArrayList<String> ids) {
        Intent intent = new Intent(context, MacReceiveService.class);
        if (ids != null) intent.putStringArrayListExtra(SELECTED, ids);
        context.startForegroundService(intent);
    }

    static void stop(Context context) {
        context.getSharedPreferences(StackStore.PREFS, 0).edit().putBoolean(MacBridgeClient.AUTO_RECEIVE, false).apply();
        context.stopService(new Intent(context, MacReceiveService.class));
    }

    private boolean automatic() {
        return getSharedPreferences(StackStore.PREFS, 0).getBoolean(MacBridgeClient.AUTO_RECEIVE, false);
    }

    @Override public void onCreate() {
        super.onCreate();
        getSystemService(NotificationManager.class).createNotificationChannel(
            new NotificationChannel("mac_receive", "Mac 파일 수신", NotificationManager.IMPORTANCE_LOW));
        wakeLock = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sharestack:receive");
        wakeLock.setReferenceCounted(false);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) { stop(this); return START_NOT_STICKY; }
        startForeground(1002, notification("Mac 파일 확인 중"));
        ArrayList<String> ids = intent == null ? null : intent.getStringArrayListExtra(SELECTED);
        if (ids != null) {
            jobs++;
            worker.execute(() -> { receive(ids); main.post(() -> { jobs--; finishIfIdle(); }); });
        }
        if (automatic() && poll == null) poll = worker.scheduleWithFixedDelay(() -> receive(null), 0, 15, TimeUnit.SECONDS);
        finishIfIdle();
        return automatic() ? START_STICKY : START_NOT_STICKY;
    }

    private void finishIfIdle() { if (!automatic() && jobs == 0) stopSelf(); }

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
            .setContentTitle("Share Stack · Mac 수신").setContentText(text).setContentIntent(open)
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
        if (active != null) active.disconnect();
        worker.shutdownNow();
        synchronized (wakeLock) { if (wakeLock.isHeld()) wakeLock.release(); }
        getSharedPreferences(StackStore.PREFS, 0).edit().putString(MacBridgeClient.RECEIVE_STATUS, "수신 중지됨").apply();
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
