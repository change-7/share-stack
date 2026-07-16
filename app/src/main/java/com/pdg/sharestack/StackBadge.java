package com.pdg.sharestack;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;

final class StackBadge {
    private static final String CHANNEL = "stack_count";
    private static final int NOTIFICATION_ID = 1001;

    private StackBadge() { }

    static void update(Context context, int count) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) return;
        if (count <= 0) {
            manager.cancel(NOTIFICATION_ID);
            return;
        }
        if (android.os.Build.VERSION.SDK_INT >= 33
            && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        NotificationChannel channel = new NotificationChannel(CHANNEL, "스택 개수", NotificationManager.IMPORTANCE_MIN);
        channel.setShowBadge(true);
        channel.setSound(null, null);
        manager.createNotificationChannel(channel);
        Intent openApp = new Intent(context, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pendingIntent = PendingIntent.getActivity(context, 0, openApp,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification notification = new Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_stack)
            .setContentTitle("Share Stack")
            .setContentText("쌓인 항목 " + count + "개")
            .setNumber(count)
            .setBadgeIconType(Notification.BADGE_ICON_SMALL)
            .setCategory(Notification.CATEGORY_STATUS)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build();
        manager.notify(NOTIFICATION_ID, notification);
    }
}
