package com.pdg.sharestack;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.List;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLPeerUnverifiedException;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

final class MacBridgeClient {
    static final String HOST = "mac_bridge_host";
    static final String TOKEN = "mac_bridge_token";
    static final String TLS_PIN = "mac_bridge_tls_pin";
    static final int PORT = 8765;
    private static final int CHUNK_SIZE = 4 * 1024 * 1024;

    private MacBridgeClient() { }

    static Pairing validate(Context context, Pairing pairing) throws IOException {
        Pairing normalized = new Pairing(pairing.host.trim(), pairing.token.trim(), pairing.certificatePin.trim().toLowerCase());
        if (!isValidPairing(normalized)) throw new IOException("Mac 주소, 짝 토큰, TLS 지문을 확인하세요");
        if (!isTailscaleIPv4(normalized.host)) {
            ConnectivityManager manager = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
            boolean onWifi = false;
            if (manager != null) {
                for (Network network : manager.getAllNetworks()) {
                    NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
                    if (capabilities != null && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                        onWifi = true;
                        break;
                    }
                }
            }
            if (!onWifi) {
                throw new IOException("같은 Wi-Fi에 연결한 뒤 다시 시도하세요");
            }
        }
        return normalized;
    }

    static boolean isValidPairing(Pairing pairing) {
        return isSupportedHost(pairing.host) && pairing.token.matches("[A-Za-z0-9_-]{43}")
            && pairing.certificatePin.matches("[0-9a-f]{64}");
    }

    static boolean isSupportedHost(String host) {
        return host != null && (isTailscaleIPv4(host) || isPrivateIPv4(host));
    }

    static int send(Context context, Pairing pairing, List<StackItem> items) throws IOException {
        pairing = validate(context, pairing);
        int sent = 0;
        for (StackItem item : items) {
            File file = StackStore.itemFile(context, item.id);
            if (!file.isFile()) throw new IOException("스택 파일을 찾을 수 없습니다: " + item.name);
            if (file.length() > StackStore.MAXIMUM_TRANSFER_SIZE) throw new IOException("최대 전송 크기는 20 GiB입니다");
            String sha256 = StackStore.fingerprint(file);
            HttpURLConnection begin = open(pairing, "/v1/uploads");
            begin.setRequestMethod("POST");
            begin.setDoOutput(true);
            begin.setFixedLengthStreamingMode(0);
            begin.setRequestProperty("X-Upload-ID", sha256);
            begin.setRequestProperty("X-Item-Name", encodeHeader(item.name));
            begin.setRequestProperty("X-Item-Mime", encodeHeader(item.mimeType));
            begin.setRequestProperty("X-Item-Size", Long.toString(file.length()));
            begin.setRequestProperty("X-Item-SHA256", sha256);
            JSONObject upload;
            try {
                begin.getOutputStream().close();
                requireSuccess(begin);
                try (InputStream input = begin.getInputStream()) {
                    upload = new JSONObject(new String(readAll(input), StandardCharsets.UTF_8));
                } catch (org.json.JSONException exception) {
                    throw new IOException("Mac 업로드 응답을 읽을 수 없습니다", exception);
                }
            } finally {
                begin.disconnect();
            }
            if (!upload.optBoolean("complete")) {
                long offset = upload.optLong("offset", -1);
                if (offset < 0 || offset > file.length()) throw new IOException("Mac 업로드 위치가 올바르지 않습니다");
                while (offset < file.length()) {
                    int length = (int) Math.min(CHUNK_SIZE, file.length() - offset);
                    byte[] chunk = new byte[length];
                    try (java.io.RandomAccessFile source = new java.io.RandomAccessFile(file, "r")) {
                        source.seek(offset);
                        source.readFully(chunk);
                    }
                    HttpURLConnection connection = open(pairing, "/v1/uploads/" + sha256);
                    connection.setRequestMethod("PUT");
                    connection.setDoOutput(true);
                    connection.setFixedLengthStreamingMode(length);
                    connection.setRequestProperty("Content-Type", "application/octet-stream");
                    connection.setRequestProperty("Content-Range", "bytes " + offset + "-" + (offset + length - 1) + "/" + file.length());
                    try {
                        try (OutputStream output = connection.getOutputStream()) { output.write(chunk); }
                        requireSuccess(connection);
                        try (InputStream input = connection.getInputStream()) {
                            JSONObject response = new JSONObject(new String(readAll(input), StandardCharsets.UTF_8));
                            long next = response.optLong("offset", -1);
                            if (next != offset + length) throw new IOException("Mac 업로드 위치가 맞지 않습니다");
                            offset = next;
                        } catch (org.json.JSONException exception) {
                            throw new IOException("Mac 업로드 응답을 읽을 수 없습니다", exception);
                        }
                    } finally {
                        connection.disconnect();
                    }
                }
                HttpURLConnection finish = open(pairing, "/v1/uploads/" + sha256 + "/finish");
                finish.setRequestMethod("POST");
                finish.setDoOutput(true);
                finish.setFixedLengthStreamingMode(0);
                try {
                    finish.getOutputStream().close();
                    requireSuccess(finish);
                } finally {
                    finish.disconnect();
                }
            }
            sent++;
        }
        return sent;
    }

    static int receive(Context context, Pairing pairing) throws IOException {
        pairing = validate(context, pairing);
        HttpURLConnection pendingConnection = open(pairing, "/v1/pending");
        JSONArray pending;
        try {
            requireSuccess(pendingConnection);
            try (InputStream input = pendingConnection.getInputStream()) {
                pending = new JSONArray(new String(readAll(input), StandardCharsets.UTF_8));
            } catch (org.json.JSONException exception) {
                throw new IOException("Mac 응답을 읽을 수 없습니다", exception);
            }
        } finally {
            pendingConnection.disconnect();
        }
        int received = 0;
        for (int index = 0; index < pending.length(); index++) {
            JSONObject item;
            try {
                item = pending.getJSONObject(index);
                String id = item.getString("id");
                if (!id.matches("[a-fA-F0-9-]{36}")) throw new IOException("Mac 항목 ID가 올바르지 않습니다");
                String name = item.getString("name");
                String mimeType = item.getString("mimeType");
                long size = item.getLong("size");
                String sha256 = item.getString("sha256");
                if (size < 0 || size > StackStore.MAXIMUM_TRANSFER_SIZE || !sha256.matches("[0-9a-f]{64}")) {
                    throw new IOException("Mac 파일 정보가 올바르지 않습니다");
                }
                File partial = StackStore.partialDownloadFile(context, id, size);
                long offset = partial.length();
                while (offset < size) {
                    int length = (int) Math.min(CHUNK_SIZE, size - offset);
                    HttpURLConnection content = open(pairing, "/v1/items/" + id + "/content");
                    content.setRequestProperty("Range", "bytes=" + offset + "-" + (offset + length - 1));
                    try {
                        if (content.getResponseCode() != HttpURLConnection.HTTP_PARTIAL
                            || !("bytes " + offset + "-" + (offset + length - 1) + "/" + size).equals(content.getHeaderField("Content-Range"))) {
                            throw new IOException("Mac 파일의 이어받기 응답이 올바르지 않습니다");
                        }
                        try (InputStream input = content.getInputStream()) {
                            StackStore.appendDownloadedRange(new StackStore.DownloadChunk(partial, offset, length), input);
                        }
                        offset += length;
                    } finally {
                        content.disconnect();
                    }
                }
                StackStore.finishDownloadedFile(context, partial,
                    new StackStore.DownloadMetadata(mimeType, name, size, sha256));
                HttpURLConnection ack = open(pairing, "/v1/items/" + id + "/ack");
                ack.setRequestMethod("POST");
                ack.setDoOutput(true);
                ack.setFixedLengthStreamingMode(0);
                try {
                    ack.getOutputStream().close();
                    requireSuccess(ack);
                } finally {
                    ack.disconnect();
                }
                received++;
            } catch (org.json.JSONException exception) {
                throw new IOException("Mac 전송 대기열 형식이 올바르지 않습니다", exception);
            }
        }
        return received;
    }

    private static HttpURLConnection open(Pairing pairing, String path) throws IOException {
        HttpsURLConnection connection = (HttpsURLConnection) new URL("https://" + pairing.host + ":" + PORT + path).openConnection();
        connection.setConnectTimeout(10_000);
        connection.setReadTimeout(120_000);
        connection.setInstanceFollowRedirects(false);
        connection.setSSLSocketFactory(pinnedSocketFactory(pairing.certificatePin));
        connection.setHostnameVerifier((host, session) -> {
            try {
                return certificateMatches(session.getPeerCertificates()[0], pairing.certificatePin);
            } catch (SSLPeerUnverifiedException | IndexOutOfBoundsException exception) {
                return false;
            }
        });
        connection.setRequestProperty("Authorization", "Bearer " + pairing.token);
        connection.setRequestProperty("Connection", "close");
        return connection;
    }

    private static SSLSocketFactory pinnedSocketFactory(String fingerprint) throws IOException {
        X509TrustManager pinningTrustManager = new X509TrustManager() {
            @Override public void checkClientTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                throw new CertificateException("Client certificates are not accepted");
            }

            @Override public void checkServerTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                if (chain == null || chain.length == 0 || !certificateMatches(chain[0], fingerprint)) {
                    throw new CertificateException("Mac TLS certificate fingerprint does not match pairing");
                }
            }

            @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        };
        try {
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, new TrustManager[] { pinningTrustManager }, new SecureRandom());
            return context.getSocketFactory();
        } catch (java.security.GeneralSecurityException exception) {
            throw new IOException("TLS 연결을 준비하지 못했습니다", exception);
        }
    }

    private static boolean certificateMatches(java.security.cert.Certificate certificate, String fingerprint) {
        try {
            byte[] expected = decodeHex(fingerprint);
            byte[] actual = MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded());
            return MessageDigest.isEqual(expected, actual);
        } catch (Exception exception) {
            return false;
        }
    }

    private static byte[] decodeHex(String value) {
        byte[] bytes = new byte[value.length() / 2];
        for (int index = 0; index < bytes.length; index++) {
            bytes[index] = (byte) Integer.parseInt(value.substring(index * 2, index * 2 + 2), 16);
        }
        return bytes;
    }

    private static void requireSuccess(HttpURLConnection connection) throws IOException {
        int status = connection.getResponseCode();
        if (status >= 200 && status < 300) return;
        String message = "Mac 연결에 실패했습니다 (HTTP " + status + ")";
        try (InputStream input = connection.getErrorStream()) {
            if (input != null) {
                byte[] body = readPrefix(input, 2048);
                JSONObject error = new JSONObject(new String(body, StandardCharsets.UTF_8));
                message = error.optString("error", message);
            }
        } catch (Exception ignored) { }
        throw new IOException(message);
    }

    private static String encodeHeader(String value) {
        return Base64.encodeToString(value.getBytes(StandardCharsets.UTF_8), Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    private static byte[] readAll(InputStream input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
        return output.toByteArray();
    }

    private static byte[] readPrefix(InputStream input, int maximum) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(maximum);
        byte[] buffer = new byte[Math.min(1024, maximum)];
        int count;
        while (output.size() < maximum
            && (count = input.read(buffer, 0, Math.min(buffer.length, maximum - output.size()))) != -1) {
            output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }

    private static boolean isTailscaleIPv4(String value) {
        String[] parts = value.split("\\.", -1);
        if (parts.length != 4) return false;
        int[] octets = new int[4];
        for (int index = 0; index < parts.length; index++) {
            if (!parts[index].matches("[0-9]{1,3}")) return false;
            if (parts[index].length() > 1 && parts[index].charAt(0) == '0') return false;
            octets[index] = Integer.parseInt(parts[index]);
            if (octets[index] > 255) return false;
        }
        return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
    }

    private static boolean isPrivateIPv4(String value) {
        String[] parts = value.split("\\.", -1);
        if (parts.length != 4) return false;
        int[] octets = new int[4];
        for (int index = 0; index < parts.length; index++) {
            if (!parts[index].matches("[0-9]{1,3}")) return false;
            if (parts[index].length() > 1 && parts[index].charAt(0) == '0') return false;
            octets[index] = Integer.parseInt(parts[index]);
            if (octets[index] > 255) return false;
        }
        return octets[0] == 10 || octets[0] == 192 && octets[1] == 168
            || octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31;
    }

    static final class Pairing {
        final String host;
        final String token;
        final String certificatePin;

        Pairing(String host, String token, String certificatePin) {
            this.host = host == null ? "" : host;
            this.token = token == null ? "" : token;
            this.certificatePin = certificatePin == null ? "" : certificatePin;
        }
    }
}
