package com.pdg.sharestack;

import android.util.Base64;

import java.nio.charset.StandardCharsets;

final class StackItem {
    final String id;
    final String mimeType;
    final String name;
    final String fingerprint;
    final long createdAt;
    final boolean locked;

    StackItem(String id, String mimeType, String name) {
        this(id, mimeType, name, null, System.currentTimeMillis());
    }

    StackItem(String id, String mimeType, String name, String fingerprint) {
        this(id, mimeType, name, fingerprint, System.currentTimeMillis());
    }

    StackItem(String id, String mimeType, String name, String fingerprint, long createdAt) {
        this(id, mimeType, name, fingerprint, createdAt, false);
    }

    StackItem(String id, String mimeType, String name, String fingerprint, long createdAt,
        boolean locked) {
        this.id = id;
        this.mimeType = mimeType;
        this.name = name;
        this.fingerprint = fingerprint;
        this.createdAt = createdAt;
        this.locked = locked;
    }

    String serialize() {
        String value = encode(id) + "," + encode(mimeType) + "," + encode(name);
        value += "," + encode(fingerprint == null ? "" : fingerprint);
        return value + "," + createdAt + "," + locked;
    }

    static StackItem deserialize(String value) {
        String[] fields = value.split(",", -1);
        if (fields.length < 3 || fields.length > 6) return null;
        try {
            return new StackItem(decode(fields[0]), decode(fields[1]), decode(fields[2]),
                fields.length >= 4 && !decode(fields[3]).isEmpty() ? decode(fields[3]) : null,
                fields.length >= 5 ? Long.parseLong(fields[4]) : 0L,
                fields.length == 6 && Boolean.parseBoolean(fields[5]));
        } catch (IllegalArgumentException ignored) {
            return null;
        }
    }

    StackItem withLocked(boolean locked) {
        return new StackItem(id, mimeType, name, fingerprint, createdAt, locked);
    }

    private static String encode(String value) {
        return Base64.encodeToString(value.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }

    private static String decode(String value) {
        return new String(Base64.decode(value, Base64.NO_WRAP), StandardCharsets.UTF_8);
    }
}
