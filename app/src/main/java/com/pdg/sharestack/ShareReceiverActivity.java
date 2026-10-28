package com.pdg.sharestack;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.TextView;
import android.widget.Toast;

public final class ShareReceiverActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        final Context app = getApplicationContext();
        final Intent share = new Intent(getIntent());
        TextView status = new TextView(this);
        status.setText("스택에 추가하는 중…");
        status.setTextColor(Color.DKGRAY);
        status.setTextSize(16);
        status.setGravity(Gravity.CENTER);
        status.setBackgroundColor(0xfff6f8fc);
        setContentView(status);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        BackgroundWork.run(() -> {
            StackStore.receive(app, share);
            return StackStore.load(app).size();
        }, (count, error) -> {
            if (error != null) {
                Toast.makeText(app, "항목을 추가할 수 없습니다", Toast.LENGTH_SHORT).show();
            } else {
                StackBadge.update(app, count == null ? 0 : count);
                if (getSharedPreferences(StackStore.PREFS, MODE_PRIVATE)
                    .getBoolean(StackStore.OPEN_AFTER_RECEIVING, false)) {
                    startActivity(new Intent(this, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP));
                }
            }
            if (!isFinishing()) finish();
        });
    }
}
