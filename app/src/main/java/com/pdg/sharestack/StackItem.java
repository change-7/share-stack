package com.pdg.sharestack;

import android.util.Base64;

import java.nio.charset.StandardCharsets;

final class StackItem {
    final String id;
    final String mimeType;
    final String name;
    final String fingerprint;

    StackItem(String id, String mimeType, String name) {
        this(id, mimeType, name, null);
    }

    StackItem(String id, String mimeType, String name, String fingerprint) {
        this.id = id;
        this.mimeType = mimeType;
        this.name = name;
        this.fingerprint = fingerprint;
    }

    String serialize() {
        String value = encode(id) + "," + encode(mimeType) + "," + encode(name);
        return fingerprint == null ? value : value + "," + encode(fingerprint);
    }

    static StackItem deserialize(String value) {
        String[] fields = value.split(",", -1);
        if (fields.length != 3 && fields.length != 4) return null;
        try {
            return new StackItem(decode(fields[0]), decode(fields[1]), decode(fields[2]),
                fields.length == 4 ? decode(fields[3]) : null);
        } catch (IllegalArgumentException ignored) {
            return null;
        }
    }

    private static String encode(String value) {
        return Base64.encodeToString(value.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }

    private static String decode(String value) {
        return new String(Base64.decode(value, Base64.NO_WRAP), StandardCharsets.UTF_8);
    }
}
