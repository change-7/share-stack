package com.pdg.sharestack;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.UUID;

final class StackStore {
    static final String PREFS = "stack";
    static final String ITEMS = "items";
    static final String CLEAR_STACK_AFTER_SHARE = "clear_and_close_after_share";
    static final String OPEN_AFTER_RECEIVING = "open_after_receiving";
    static final String SHOW_NOTIFICATION_SHARE_ACTION = "show_notification_share_action";

    private StackStore() { }

    static ArrayList<StackItem> load(Context context) {
        File directory = itemDirectory(context);
        ArrayList<StackItem> result = new ArrayList<>();
        String saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(ITEMS, "");
        if (!saved.isEmpty()) {
            for (String row : saved.split("\\n")) {
                StackItem item = StackItem.deserialize(row);
                if (item != null && new File(directory, item.id).isFile()) result.add(item);
            }
        }
        return result;
    }

    static void save(Context context, ArrayList<StackItem> items) {
        StringBuilder data = new StringBuilder();
        for (StackItem item : items) {
            if (data.length() > 0) data.append('\n');
            data.append(item.serialize());
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(ITEMS, data.toString()).commit();
    }

    @SuppressWarnings("deprecation")
    static int receive(Context context, Intent intent) {
        ArrayList<StackItem> items = load(context);
        boolean added = false;
        String text = intent.getStringExtra(Intent.EXTRA_TEXT);
        if (text != null && !text.isEmpty()) {
            String id = UUID.randomUUID().toString() + ".txt";
            File destination = itemFile(context, id);
            if (writeBytes(destination, text.getBytes(StandardCharsets.UTF_8))
                && addUniqueItem(context, items, destination, "text/plain", shorten(text))) {
                added = true;
            }
        }

        ArrayList<Uri> uris = new ArrayList<>();
        if (Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())) {
            ArrayList<Uri> multiple = android.os.Build.VERSION.SDK_INT >= 33
                ? intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri.class)
                : intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (multiple != null) uris.addAll(multiple);
        } else {
            Uri stream = android.os.Build.VERSION.SDK_INT >= 33
                ? intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class)
                : intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (stream != null) uris.add(stream);
        }
        if (intent.getClipData() != null) {
            for (int i = 0; i < intent.getClipData().getItemCount(); i++) {
                Uri uri = intent.getClipData().getItemAt(i).getUri();
                if (uri != null && !uris.contains(uri)) uris.add(uri);
            }
        }
        for (Uri uri : uris) if (copyUri(context, uri, intent.getType(), items)) added = true;

        if (added) save(context, items);
        return items.size();
    }

    static File itemFile(Context context, String id) {
        return new File(itemDirectory(context), id);
    }

    private static File itemDirectory(Context context) {
        File directory = new File(context.getFilesDir(), "items");
        directory.mkdirs();
        return directory;
    }

    private static boolean copyUri(Context context, Uri uri, String fallbackType, ArrayList<StackItem> items) {
        String id = UUID.randomUUID().toString();
        File destination = itemFile(context, id);
        try (InputStream input = context.getContentResolver().openInputStream(uri);
             FileOutputStream output = new FileOutputStream(destination)) {
            if (input == null) return false;
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            String type = context.getContentResolver().getType(uri);
            if (type == null) type = fallbackType == null ? "application/octet-stream" : fallbackType;
            return addUniqueItem(context, items, destination, type, displayName(context, uri));
        } catch (IOException ignored) {
            destination.delete();
            return false;
        }
    }

    private static boolean writeBytes(File destination, byte[] data) {
        try (FileOutputStream output = new FileOutputStream(destination)) {
            output.write(data);
            return true;
        } catch (IOException ignored) {
            destination.delete();
            return false;
        }
    }

    private static boolean addUniqueItem(Context context, ArrayList<StackItem> items, File file, String mimeType, String name) {
        String fingerprint = fingerprint(file);
        for (StackItem item : items) {
            if (fingerprint.equals(item.fingerprint) || (item.fingerprint == null && sameContents(file, itemFile(context, item.id)))) {
                file.delete();
                return false;
            }
        }
        items.add(new StackItem(file.getName(), mimeType, name, fingerprint));
        return true;
    }

    private static String fingerprint(File file) {
        try (InputStream input = new java.io.FileInputStream(file)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) digest.update(buffer, 0, count);
            StringBuilder result = new StringBuilder();
            for (byte value : digest.digest()) result.append(String.format("%02x", value & 0xff));
            return result.toString();
        } catch (IOException | NoSuchAlgorithmException exception) {
            throw new IllegalStateException("항목 내용을 확인할 수 없습니다", exception);
        }
    }

    private static boolean sameContents(File first, File second) {
        if (first.length() != second.length()) return false;
        try (InputStream firstInput = new java.io.FileInputStream(first);
             InputStream secondInput = new java.io.FileInputStream(second)) {
            byte[] firstBuffer = new byte[8192];
            byte[] secondBuffer = new byte[8192];
            int firstCount;
            while ((firstCount = firstInput.read(firstBuffer)) != -1) {
                int secondCount = secondInput.read(secondBuffer);
                if (firstCount != secondCount) return false;
                for (int i = 0; i < firstCount; i++) if (firstBuffer[i] != secondBuffer[i]) return false;
            }
            return secondInput.read() == -1;
        } catch (IOException ignored) {
            return false;
        }
    }

    private static String displayName(Context context, Uri uri) {
        try (Cursor cursor = context.getContentResolver().query(uri, null, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (column >= 0) return cursor.getString(column);
            }
        } catch (Exception ignored) { }
        return uri.getLastPathSegment() == null ? "공유 항목" : uri.getLastPathSegment();
    }

    private static String shorten(String text) {
        return text.length() > 80 ? text.substring(0, 77) + "…" : text;
    }
}
