package com.pdg.sharestack;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

public final class ShareReceiverActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        int count = StackStore.receive(this, getIntent());
        StackBadge.update(this, count);
        if (getSharedPreferences(StackStore.PREFS, MODE_PRIVATE)
            .getBoolean(StackStore.OPEN_AFTER_RECEIVING, false)) {
            startActivity(new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP));
        }
        finish();
    }
}
