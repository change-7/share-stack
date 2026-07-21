package com.pdg.sharestack;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentSender;
import android.net.Uri;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

public final class ShareSelectionReceiver extends BroadcastReceiver {
    private static final String ITEM_IDS = "item_ids";

    static IntentSender forItems(Context context, List<StackItem> items) {
        ArrayList<String> itemIds = new ArrayList<>();
        for (StackItem item : items) itemIds.add(item.id);
        Intent result = new Intent(context, ShareSelectionReceiver.class)
            .setData(Uri.parse("sharestack://selection/" + UUID.randomUUID()))
            .putStringArrayListExtra(ITEM_IDS, itemIds);
        PendingIntent pendingIntent = PendingIntent.getBroadcast(context, 0, result,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
        return pendingIntent.getIntentSender();
    }

    @Override public void onReceive(Context context, Intent intent) {
        ArrayList<String> itemIds = intent.getStringArrayListExtra(ITEM_IDS);
        if (itemIds == null || itemIds.isEmpty()) return;
        StackBadge.update(context, StackStore.remove(context, itemIds));
    }
}
