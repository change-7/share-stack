package com.pdg.sharestack;

import android.content.Intent;
import android.service.quicksettings.TileService;

public final class QuickCameraTileService extends TileService {
    @Override public void onClick() {
        Intent capture = new Intent(this, CaptureActivity.class)
            .putExtra(CaptureActivity.EXTRA_CAPTURE_ID, java.util.UUID.randomUUID() + ".jpg")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivityAndCollapse(capture);
    }
}
