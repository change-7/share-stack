package com.pdg.sharestack;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

public final class NotificationShareActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (getSharedPreferences(StackStore.PREFS, MODE_PRIVATE)
            .getBoolean(StackStore.SHOW_NOTIFICATION_SHARE_ACTION, false)) {
            shareAll();
        }
        finish();
    }

    private void shareAll() {
        ArrayList<StackItem> items = StackStore.load(this);
        if (items.isEmpty()) return;
        boolean clearAfterShare = getSharedPreferences(StackStore.PREFS, MODE_PRIVATE)
            .getBoolean(StackStore.CLEAR_STACK_AFTER_SHARE, false);
        ArrayList<Uri> uris = new ArrayList<>();
        ArrayList<StackItem> files = new ArrayList<>();
        String text = selectedText(items);
        for (StackItem item : items) if (!"text/plain".equals(item.mimeType)) files.add(item);
        if (files.isEmpty()) {
            if (!text.isEmpty()) copyText(text);
            if (clearAfterShare) clearStack(items);
            return;
        }
        for (StackItem item : files) {
            String id = clearAfterShare ? copyForSharing(item) : item.id;
            if (id == null) return;
            uris.add(contentUri(clearAfterShare ? "shared/" : "", id, item.name, item.mimeType));
        }
        Intent send = new Intent(uris.size() == 1 ? Intent.ACTION_SEND : Intent.ACTION_SEND_MULTIPLE);
        send.setType(commonType(files));
        ClipData clipData = ClipData.newRawUri("Share Stack items", uris.get(0));
        for (int index = 1; index < uris.size(); index++) clipData.addItem(new ClipData.Item(uris.get(index)));
        send.setClipData(clipData);
        send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        if (uris.size() == 1) send.putExtra(Intent.EXTRA_STREAM, uris.get(0));
        else send.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
        if (!text.isEmpty()) copyText(text);
        Intent chooser = clearAfterShare
            ? Intent.createChooser(send, "선택 항목 공유", ShareSelectionReceiver.forItems(this, items))
            : Intent.createChooser(send, "선택 항목 공유");
        startActivity(chooser);
    }

    private String selectedText(List<StackItem> items) {
        StringBuilder text = new StringBuilder();
        for (StackItem item : items) if ("text/plain".equals(item.mimeType)) {
            try (FileInputStream input = new FileInputStream(itemFile(item.id))) {
                byte[] bytes = new byte[input.available()];
                input.read(bytes);
                if (text.length() > 0) text.append("\n\n");
                text.append(new String(bytes, StandardCharsets.UTF_8));
            } catch (IOException ignored) { }
        }
        return text.toString();
    }

    private String copyForSharing(StackItem item) {
        String id = UUID.randomUUID().toString();
        File sharedFile = new File(getFilesDir(), "shared/" + id);
        sharedFile.getParentFile().mkdirs();
        try (FileInputStream input = new FileInputStream(itemFile(item.id));
             FileOutputStream output = new FileOutputStream(sharedFile)) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            return id;
        } catch (IOException exception) {
            sharedFile.delete();
            Toast.makeText(this, "공유 파일을 준비할 수 없습니다", Toast.LENGTH_SHORT).show();
            return null;
        }
    }

    private String commonType(List<StackItem> items) {
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

    private void copyText(String text) {
        ((ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE))
            .setPrimaryClip(ClipData.newPlainText("Share Stack", text));
    }

    private void clearStack(List<StackItem> items) {
        for (StackItem item : items) itemFile(item.id).delete();
        StackStore.save(this, new ArrayList<>());
        StackBadge.update(this, 0);
    }

    private File itemFile(String id) {
        return StackStore.itemFile(this, id);
    }

    private Uri contentUri(String directory, String id, String name, String type) {
        return Uri.parse("content://com.pdg.sharestack.items/" + directory + id
            + "?name=" + Uri.encode(name) + "&type=" + Uri.encode(type));
    }
}
