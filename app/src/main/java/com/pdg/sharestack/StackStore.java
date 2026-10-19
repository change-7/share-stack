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
    static final String KEEP_STACK_NOTIFICATION = "keep_stack_notification";
    static final String AUTO_EXPIRY_DAYS = "auto_expiry_days";
    static final String SAVE_URL_WITH_MEDIA = "save_url_with_media";
    static final long MAXIMUM_TRANSFER_SIZE = 20L * 1024 * 1024 * 1024;

    private StackStore() { }

    static ArrayList<StackItem> load(Context context) {
        File directory = itemDirectory(context);
        ArrayList<StackItem> result = new ArrayList<>();
        String saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(ITEMS, "");
        boolean changed = false;
        int expiryDays = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(AUTO_EXPIRY_DAYS, 0);
        long cutoff = expiryDays <= 0 ? Long.MIN_VALUE
            : System.currentTimeMillis() - expiryDays * 24L * 60L * 60L * 1000L;
        if (!saved.isEmpty()) {
            for (String row : saved.split("\\n")) {
                StackItem item = StackItem.deserialize(row);
                if (item == null) {
                    changed = true;
                    continue;
                }
                File file = new File(directory, item.id);
                if (!file.isFile()) {
                    changed = true;
                    continue;
                }
                long createdAt = item.createdAt > 0 ? item.createdAt : file.lastModified();
                if (createdAt < cutoff) {
                    file.delete();
                    changed = true;
                    continue;
                }
                result.add(item);
            }
        }
        if (changed) save(context, result);
        return result;
    }

    static boolean save(Context context, ArrayList<StackItem> items) {
        StringBuilder data = new StringBuilder();
        for (StackItem item : items) {
            if (data.length() > 0) data.append('\n');
            data.append(item.serialize());
        }
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(ITEMS, data.toString()).commit();
    }

    static int remove(Context context, ArrayList<String> itemIds) {
        ArrayList<StackItem> remaining = new ArrayList<>();
        for (StackItem item : load(context)) {
            if (itemIds.contains(item.id) && !item.locked) itemFile(context, item.id).delete();
            else remaining.add(item);
        }
        save(context, remaining);
        return remaining.size();
    }

    static int removeUnlocked(Context context) {
        ArrayList<StackItem> items = load(context);
        ArrayList<String> itemIds = new ArrayList<>();
        for (StackItem item : items) if (!item.locked) itemIds.add(item.id);
        return remove(context, itemIds);
    }

    @SuppressWarnings("deprecation")
    static int receive(Context context, Intent intent) {
        ArrayList<StackItem> items = load(context);
        boolean added = false;
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
        String text = intent.getStringExtra(Intent.EXTRA_TEXT);
        boolean saveUrlWithMedia = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(SAVE_URL_WITH_MEDIA, true);
        if (text != null && !text.isEmpty()
            && (uris.isEmpty() || saveUrlWithMedia || !isWebUrl(text))) {
            String id = UUID.randomUUID().toString() + ".txt";
            File destination = itemFile(context, id);
            if (writeBytes(destination, text.getBytes(StandardCharsets.UTF_8))
                && addUniqueItem(context, items, destination, "text/plain", shorten(text))) {
                added = true;
            }
        }
        for (Uri uri : uris) if (copyUri(context, uri, intent.getType(), items)) added = true;

        if (added) save(context, items);
        return items.size();
    }

    static File itemFile(Context context, String id) {
        return new File(itemDirectory(context), id);
    }

    static File partialDownloadFile(Context context, String remoteId, long totalSize) throws IOException {
        if (remoteId == null || !remoteId.matches("[a-fA-F0-9-]{36}")
            || totalSize < 0 || totalSize > MAXIMUM_TRANSFER_SIZE) {
            throw new IOException("Mac 파일 정보가 올바르지 않습니다");
        }
        File directory = new File(context.getFilesDir(), "downloads");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("이어받기 폴더를 만들지 못했습니다");
        File partial = new File(directory, remoteId + ".part");
        if (partial.isFile() && partial.length() > totalSize && !partial.delete()) {
            throw new IOException("잘못된 임시 파일을 지우지 못했습니다");
        }
        if (!partial.exists() && !partial.createNewFile()) throw new IOException("이어받기 파일을 만들지 못했습니다");
        return partial;
    }

    static void appendDownloadedRange(DownloadChunk chunk, InputStream input) throws IOException {
        if (chunk.offset < 0 || chunk.length <= 0 || chunk.length > 4 * 1024 * 1024
            || chunk.offset != chunk.partial.length()) {
            throw new IOException("다운로드 이어받기 위치가 올바르지 않습니다");
        }
        try (java.io.RandomAccessFile output = new java.io.RandomAccessFile(chunk.partial, "rw")) {
            output.seek(chunk.offset);
            byte[] buffer = new byte[64 * 1024];
            int remaining = chunk.length;
            while (remaining > 0) {
                int count = input.read(buffer, 0, Math.min(buffer.length, remaining));
                if (count == -1) throw new IOException("다운로드 조각이 완전히 도착하지 않았습니다");
                output.write(buffer, 0, count);
                remaining -= count;
            }
            if (input.read() != -1) throw new IOException("다운로드 조각이 예상 크기보다 큽니다");
            output.getFD().sync();
        }
    }

    static boolean finishDownloadedFile(Context context, File partial, DownloadMetadata metadata) throws IOException {
        if (metadata.size < 0 || metadata.size > MAXIMUM_TRANSFER_SIZE
            || !metadata.sha256.matches("[0-9a-f]{64}") || partial.length() != metadata.size) {
            throw new IOException("받은 파일 정보가 올바르지 않습니다");
        }
        String actual = fingerprint(partial);
        if (!metadata.sha256.equals(actual)) {
            partial.delete();
            throw new IOException("전송 파일 검증에 실패했습니다");
        }
        File destination = itemFile(context, UUID.randomUUID().toString());
        try {
            java.nio.file.Files.move(partial.toPath(), destination.toPath());
        } catch (java.io.IOException exception) {
            throw new IOException("받은 파일을 보관함으로 옮기지 못했습니다", exception);
        }
        ArrayList<StackItem> items = load(context);
        boolean added = addUniqueItem(context, items, destination, metadata.mimeType, metadata.name);
        if (added && !save(context, items)) {
            destination.delete();
            throw new IOException("받은 항목을 스택에 저장하지 못했습니다");
        }
        return added;
    }

    static final class DownloadChunk {
        final File partial;
        final long offset;
        final int length;

        DownloadChunk(File partial, long offset, int length) {
            this.partial = partial;
            this.offset = offset;
            this.length = length;
        }
    }

    static final class DownloadMetadata {
        final String mimeType;
        final String name;
        final long size;
        final String sha256;

        DownloadMetadata(String mimeType, String name, long size, String sha256) {
            this.mimeType = mimeType;
            this.name = name;
            this.size = size;
            this.sha256 = sha256;
        }
    }

    static boolean receiveDownloaded(Context context, InputStream input, String mimeType, String name,
        long expectedSize, String expectedFingerprint) throws IOException {
        if (expectedSize < 0 || expectedSize > MAXIMUM_TRANSFER_SIZE
            || expectedFingerprint == null || !expectedFingerprint.matches("[0-9a-f]{64}")) {
            throw new IOException("전송 파일 정보가 올바르지 않습니다");
        }
        ArrayList<StackItem> items = load(context);
        File destination = itemFile(context, UUID.randomUUID().toString());
        try (FileOutputStream output = new FileOutputStream(destination)) {
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
        } catch (IOException exception) {
            destination.delete();
            throw exception;
        }
        String actualFingerprint;
        try {
            actualFingerprint = fingerprint(destination);
        } catch (IllegalStateException exception) {
            destination.delete();
            throw new IOException("받은 파일을 확인할 수 없습니다", exception);
        }
        if (destination.length() != expectedSize || !expectedFingerprint.equals(actualFingerprint)) {
            destination.delete();
            throw new IOException("전송 파일 검증에 실패했습니다");
        }
        boolean added = addUniqueItem(context, items, destination, mimeType, name);
        if (added && !save(context, items)) {
            destination.delete();
            throw new IOException("받은 항목을 스택에 저장하지 못했습니다");
        }
        return added;
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

    static String fingerprint(File file) {
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

    private static boolean isWebUrl(String text) {
        Uri uri = Uri.parse(text.trim());
        String scheme = uri.getScheme();
        return uri.getHost() != null && ("http".equalsIgnoreCase(scheme) || "https".equalsIgnoreCase(scheme));
    }
}
