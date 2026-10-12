package com.pdg.sharestack;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.service.quicksettings.TileService;
import android.widget.Toast;

public final class QuickClipboardTileService extends TileService {
    @Override public void onClick() {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard == null || !clipboard.hasPrimaryClip()) {
            Toast.makeText(this, "복사된 텍스트가 없습니다", Toast.LENGTH_SHORT).show();
            return;
        }
        ClipData clip = clipboard.getPrimaryClip();
        CharSequence text = clip == null || clip.getItemCount() == 0 ? null : clip.getItemAt(0).coerceToText(this);
        if (text == null || text.length() == 0) {
            Toast.makeText(this, "복사된 텍스트가 없습니다", Toast.LENGTH_SHORT).show();
            return;
        }
        int count = StackStore.receive(this, new Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, text.toString()));
        StackBadge.update(this, count);
        Toast.makeText(this, "텍스트를 스택에 추가했습니다", Toast.LENGTH_SHORT).show();
    }
}
