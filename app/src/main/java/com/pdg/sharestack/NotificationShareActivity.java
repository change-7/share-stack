package com.pdg.sharestack;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

public final class NotificationShareActivity extends Activity {
    static final String EXTRA_FORCE_SHARE = "force_share";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (!getSharedPreferences(StackStore.PREFS, MODE_PRIVATE)
            .getBoolean(StackStore.SHOW_NOTIFICATION_SHARE_ACTION, false)
            && !getIntent().getBooleanExtra(EXTRA_FORCE_SHARE, false)) {
            finish();
            return;
        }
        final Context app = getApplicationContext();
        TextView status = new TextView(this);
        status.setText("공유 준비 중…");
        status.setTextColor(Color.DKGRAY);
        status.setTextSize(16);
        status.setGravity(Gravity.CENTER);
        status.setBackgroundColor(0xfff6f8fc);
        setContentView(status);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        BackgroundWork.run(() -> prepare(app), (prepared, error) -> {
            if (prepared == null) {
                if (error != null) Toast.makeText(app, "공유 파일을 준비할 수 없습니다", Toast.LENGTH_SHORT).show();
                if (!isFinishing()) finish();
                return;
            }
            launch(prepared);
        });
    }

    private Prepared prepare(Context app) throws IOException {
        ArrayList<StackItem> items = StackStore.load(app);
        if (items.isEmpty()) return null;
        boolean clearAfterShare = app.getSharedPreferences(StackStore.PREFS, MODE_PRIVATE)
            .getBoolean(StackStore.CLEAR_STACK_AFTER_SHARE, false);
        String text = selectedText(app, items);
        ArrayList<StackItem> files = new ArrayList<>();
        for (StackItem item : items) if (!"text/plain".equals(item.mimeType)) files.add(item);
        ArrayList<Uri> uris = new ArrayList<>();
        String type = "text/plain";
        if (!files.isEmpty()) {
            for (StackItem item : files) {
                String id = clearAfterShare ? copyForSharing(app, item) : item.id;
                uris.add(contentUri(clearAfterShare ? "shared/" : "", id, item.name, item.mimeType));
            }
            type = commonType(files);
        }
        return new Prepared(uris, type, text, items, clearAfterShare);
    }

    private void launch(Prepared prepared) {
        if (prepared.uris.isEmpty() && prepared.text.isEmpty()) { finish(); return; }
        Intent send = new Intent(prepared.uris.size() <= 1 ? Intent.ACTION_SEND : Intent.ACTION_SEND_MULTIPLE);
        send.setType(prepared.type);
        if (!prepared.uris.isEmpty()) {
            ClipData clipData = ClipData.newRawUri("Share Stack items", prepared.uris.get(0));
            for (int index = 1; index < prepared.uris.size(); index++) {
                clipData.addItem(new ClipData.Item(prepared.uris.get(index)));
            }
            send.setClipData(clipData);
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        }
        if (prepared.uris.size() == 1) send.putExtra(Intent.EXTRA_STREAM, prepared.uris.get(0));
        else if (!prepared.uris.isEmpty()) send.putParcelableArrayListExtra(Intent.EXTRA_STREAM, prepared.uris);
        if (!prepared.text.isEmpty()) send.putExtra(Intent.EXTRA_TEXT, prepared.text);
        Intent chooser = prepared.clearAfterShare
            ? Intent.createChooser(send, "선택 항목 공유", ShareSelectionReceiver.forItems(this, prepared.items))
            : Intent.createChooser(send, "선택 항목 공유");
        try {
            startActivity(chooser);
        } catch (ActivityNotFoundException exception) {
            Toast.makeText(this, "공유할 앱을 찾을 수 없습니다", Toast.LENGTH_SHORT).show();
        }
        finish();
    }

    private static String selectedText(Context app, List<StackItem> items) {
        StringBuilder text = new StringBuilder();
        for (StackItem item : items) if ("text/plain".equals(item.mimeType)) {
            try (FileInputStream input = new FileInputStream(StackStore.itemFile(app, item.id))) {
                byte[] bytes = readAll(input);
                if (text.length() > 0) text.append("\n\n");
                text.append(new String(bytes, StandardCharsets.UTF_8));
            } catch (IOException ignored) { }
        }
        return text.toString();
    }

    private static String copyForSharing(Context app, StackItem item) throws IOException {
        String id = UUID.randomUUID().toString();
        File sharedFile = new File(app.getFilesDir(), "shared/" + id);
        sharedFile.getParentFile().mkdirs();
        try (FileInputStream input = new FileInputStream(StackStore.itemFile(app, item.id));
             FileOutputStream output = new FileOutputStream(sharedFile)) {
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            return id;
        } catch (IOException exception) {
            sharedFile.delete();
            throw exception;
        }
    }

    private static byte[] readAll(InputStream input) throws IOException {
        java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
        byte[] buffer = new byte[64 * 1024];
        int count;
        while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
        return output.toByteArray();
    }

    private static String commonType(List<StackItem> items) {
        String type = items.get(0).mimeType;
        boolean exactMatch = true;
        int slash = type.indexOf('/');
        if (slash <= 0) return "*/*";
        String family = type.substring(0, slash);
        for (StackItem item : items) {
            if (!type.equals(item.mimeType)) exactMatch = false;
            int itemSlash = item.mimeType.indexOf('/');
            if (itemSlash <= 0 || !family.equals(item.mimeType.substring(0, itemSlash))) return "*/*";
        }
        return exactMatch ? type : family + "/*";
    }

    private static Uri contentUri(String directory, String id, String name, String type) {
        return Uri.parse("content://com.pdg.sharestack.items/" + directory + id
            + "?name=" + Uri.encode(name) + "&type=" + Uri.encode(type));
    }

    private static final class Prepared {
        final ArrayList<Uri> uris;
        final String type;
        final String text;
        final ArrayList<StackItem> items;
        final boolean clearAfterShare;

        Prepared(ArrayList<Uri> uris, String type, String text, ArrayList<StackItem> items,
                 boolean clearAfterShare) {
            this.uris = uris;
            this.type = type;
            this.text = text;
            this.items = items;
            this.clearAfterShare = clearAfterShare;
        }
    }
}
