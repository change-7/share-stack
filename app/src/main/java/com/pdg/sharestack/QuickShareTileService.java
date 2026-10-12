package com.pdg.sharestack;

import android.content.Intent;
import android.service.quicksettings.TileService;

public final class QuickShareTileService extends TileService {
    @Override public void onClick() {
        Intent share = new Intent(this, NotificationShareActivity.class)
            .putExtra(NotificationShareActivity.EXTRA_FORCE_SHARE, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivityAndCollapse(share);
    }
}
