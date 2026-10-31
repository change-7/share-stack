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
import java.io.EOFException;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.HttpURLConnection;
import java.net.NoRouteToHostException;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.List;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
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
    static final String AUTO_RECEIVE = "mac_bridge_auto_receive";
    static final String AUTO_SEND = "mac_bridge_auto_send";
    static final String RECEIVE_STATUS = "mac_bridge_receive_status";
    static final int PORT = 8765;
    private static final int CHUNK_SIZE = 8 * 1024 * 1024;
    private static final int MAX_RETRIES = 3;
    private static final Object[] UPLOAD_LOCKS = new Object[16];

    static {
        for (int index = 0; index < UPLOAD_LOCKS.length; index++) UPLOAD_LOCKS[index] = new Object();
    }

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
        Pairing validated = validate(context, pairing);
        int sent = 0;
        for (StackItem item : items) {
            upload(context, validated, item, null);
            sent++;
        }
        return sent;
    }

    static JSONObject upload(Context context, Pairing validated, StackItem item, ReceiveControl control) throws IOException {
        File file = StackStore.itemFile(context, item.id);
        if (!file.isFile()) throw new IOException("스택 파일을 찾을 수 없습니다: " + item.name);
        if (file.length() > StackStore.MAXIMUM_TRANSFER_SIZE) throw new IOException("최대 전송 크기는 20 GiB입니다");
        String sha256 = StackStore.fingerprint(file, () -> control != null && control.cancelled());
        long fileLength = file.length();
        synchronized (UPLOAD_LOCKS[sha256.hashCode() & (UPLOAD_LOCKS.length - 1)]) {
            byte[] buffer = new byte[64 * 1024];
            try (java.io.RandomAccessFile source = new java.io.RandomAccessFile(file, "r")) {
                JSONObject upload = retry(() -> beginUpload(validated, item, fileLength, sha256, control), control);
                boolean complete = upload.optBoolean("complete");
                long offset = upload.optLong("offset", -1);
                if (offset < 0 || offset > fileLength) throw new IOException("Mac 업로드 위치가 올바르지 않습니다");
                while (!complete && offset < fileLength) {
                    int retries = 0;
                    while (true) {
                        checkCancelled(control);
                        int length = (int) Math.min(CHUNK_SIZE, fileLength - offset);
                        try {
                            long start = offset;
                            long next = sendUploadChunk(validated, sha256, source, buffer, start, length, fileLength, control);
                            if (next != start + length) throw new IOException("Mac 업로드 위치가 맞지 않습니다");
                            offset = next;
                            if (control != null) control.uploadProgress(item, offset, fileLength);
                            break;
                        } catch (IOException error) {
                            if (retries >= MAX_RETRIES || !retryable(error)) throw error;
                            waitForRetry(retries++, error, control);
                            upload = retry(() -> beginUpload(validated, item, fileLength, sha256, control), control);
                            complete = upload.optBoolean("complete");
                            offset = upload.optLong("offset", -1);
                            if (offset < 0 || offset > fileLength) {
                                throw new IOException("Mac 업로드 위치가 올바르지 않습니다");
                            }
                            if (complete) break;
                        }
                    }
                }
                checkCancelled(control);
                return retry(() -> finishUpload(validated, sha256, control), control);
            }
        }
    }

    static JSONObject syncAIRead(Pairing pairing, AIReadIntent intent, JSONObject uploaded,
        ReceiveControl control) throws IOException {
        HttpURLConnection connection = open(pairing, "/v1/phone-ai-read");
        track(control, connection);
        try {
            JSONObject body = new JSONObject().put("id", intent.id).put("revision", intent.revision).put("allowed", intent.allowed);
            if (intent.allowed) {
                body.put("sourceID", uploaded.getString("id")).put("sha256", uploaded.getString("sha256"));
            }
            byte[] data = body.toString().getBytes(StandardCharsets.UTF_8);
            connection.setRequestMethod("POST");
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(data.length);
            try (OutputStream output = connection.getOutputStream()) { output.write(data); }
            requireSuccess(connection);
            try (InputStream input = connection.getInputStream()) {
                return new JSONObject(new String(readAll(input), StandardCharsets.UTF_8));
            }
        } catch (org.json.JSONException error) {
            throw new IOException("Mac AI 읽기 응답을 확인할 수 없습니다", error);
        } finally { connection.disconnect(); }
    }

    private static JSONObject beginUpload(Pairing pairing, StackItem item, long size, String sha256, ReceiveControl control) throws IOException {
        HttpURLConnection connection = open(pairing, "/v1/uploads");
        track(control, connection);
        connection.setRequestMethod("POST");
        connection.setDoOutput(true);
        connection.setFixedLengthStreamingMode(0);
        connection.setRequestProperty("X-Upload-ID", sha256);
        connection.setRequestProperty("X-Item-Name", encodeHeader(item.name));
        connection.setRequestProperty("X-Item-Mime", encodeHeader(item.mimeType));
        connection.setRequestProperty("X-Item-Size", Long.toString(size));
        connection.setRequestProperty("X-Item-SHA256", sha256);
        try {
            connection.getOutputStream().close();
            requireSuccess(connection);
            try (InputStream input = connection.getInputStream()) {
                return new JSONObject(new String(readAll(input), StandardCharsets.UTF_8));
            } catch (org.json.JSONException exception) {
                throw new IOException("Mac 업로드 응답을 읽을 수 없습니다", exception);
            }
        } finally {
            connection.disconnect();
        }
    }

    private static long sendUploadChunk(Pairing pairing, String sha256,
        java.io.RandomAccessFile source, byte[] buffer, long offset, int length, long fileLength, ReceiveControl control) throws IOException {
        HttpURLConnection connection = open(pairing, "/v1/uploads/" + sha256);
        track(control, connection);
        connection.setRequestMethod("PUT");
        connection.setDoOutput(true);
        connection.setFixedLengthStreamingMode(length);
        connection.setRequestProperty("Content-Type", "application/octet-stream");
        connection.setRequestProperty("Content-Range", "bytes " + offset + "-" + (offset + length - 1) + "/" + fileLength);
        try {
            try (OutputStream output = connection.getOutputStream()) {
                source.seek(offset);
                int remaining = length;
                while (remaining > 0) {
                    checkCancelled(control);
                    int count = source.read(buffer, 0, Math.min(buffer.length, remaining));
                    if (count < 0) throw new IOException("전송 중 원본 파일이 짧아졌습니다");
                    output.write(buffer, 0, count);
                    remaining -= count;
                }
            }
            requireSuccess(connection);
            try (InputStream input = connection.getInputStream()) {
                return new JSONObject(new String(readAll(input), StandardCharsets.UTF_8)).optLong("offset", -1);
            } catch (org.json.JSONException exception) {
                throw new IOException("Mac 업로드 응답을 읽을 수 없습니다", exception);
            }
        } finally {
            connection.disconnect();
        }
    }

    private static JSONObject finishUpload(Pairing pairing, String sha256, ReceiveControl control) throws IOException {
        HttpURLConnection connection = open(pairing, "/v1/uploads/" + sha256 + "/finish");
        track(control, connection);
        connection.setRequestMethod("POST");
        connection.setDoOutput(true);
        connection.setFixedLengthStreamingMode(0);
        try {
            connection.getOutputStream().close();
            requireSuccess(connection);
            try (InputStream input = connection.getInputStream()) {
                return new JSONObject(new String(readAll(input), StandardCharsets.UTF_8));
            } catch (org.json.JSONException exception) {
                throw new IOException("Mac 업로드 응답을 읽을 수 없습니다", exception);
            }
        } finally {
            connection.disconnect();
        }
    }

    interface ReceiveControl {
        boolean cancelled();
        void connection(HttpURLConnection connection);
        void progress(PendingItem item, long offset);
        default void uploadProgress(StackItem item, long offset, long size) {}
    }

    static Pairing savedPairing(Context context) {
        android.content.SharedPreferences preferences = context.getSharedPreferences(StackStore.PREFS, Context.MODE_PRIVATE);
        return new Pairing(preferences.getString(HOST, ""), preferences.getString(TOKEN, ""), preferences.getString(TLS_PIN, ""));
    }

    static final class PendingItem {
        final String id, name, mimeType, sha256;
        final long size;

        PendingItem(JSONObject value) throws org.json.JSONException, IOException {
            id = value.getString("id");
            name = value.getString("name");
            mimeType = value.getString("mimeType");
            sha256 = value.getString("sha256");
            size = value.getLong("size");
            if (!id.matches("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")
                || name.isEmpty() || mimeType.isEmpty() || size < 0 || size > StackStore.MAXIMUM_TRANSFER_SIZE
                || !sha256.matches("[0-9a-f]{64}")) throw new IOException("Mac 파일 정보가 올바르지 않습니다");
        }
    }

    static void checkConnection(Context context, Pairing pairing) throws IOException {
        HttpURLConnection connection = open(validate(context, pairing), "/v1/pending");
        connection.setConnectTimeout(3000);
        connection.setReadTimeout(3000);
        try {
            requireSuccess(connection);
        } finally {
            connection.disconnect();
        }
    }

    static List<PendingItem> pending(Context context, Pairing pairing) throws IOException {
        return retry(() -> pending(context, pairing, null), null);
    }

    private static List<PendingItem> pending(Context context, Pairing pairing, ReceiveControl control) throws IOException {
        pairing = validate(context, pairing);
        HttpURLConnection pendingConnection = open(pairing, "/v1/pending");
        track(control, pendingConnection);
        try {
            requireSuccess(pendingConnection);
            try (InputStream input = pendingConnection.getInputStream()) {
                JSONArray values = new JSONArray(new String(readAll(input), StandardCharsets.UTF_8));
                ArrayList<PendingItem> result = new ArrayList<>();
                for (int index = 0; index < values.length(); index++) result.add(new PendingItem(values.getJSONObject(index)));
                return result;
            } catch (org.json.JSONException exception) {
                throw new IOException("Mac 응답을 읽을 수 없습니다", exception);
            }
        } finally {
            pendingConnection.disconnect();
        }
    }

    static int receive(Context context, Pairing pairing) throws IOException {
        return receive(context, pairing, null, null);
    }

    static synchronized int receive(Context context, Pairing pairing, List<String> selectedIDs, ReceiveControl control) throws IOException {
        Pairing validated = validate(context, pairing);
        List<PendingItem> pending = retry(() -> pending(context, validated, control), control);
        Set<String> selected = selectedIDs == null ? null : new HashSet<>(selectedIDs);
        int received = 0;
        IOException failure = null;
        for (PendingItem item : pending) {
            if (selected != null && !selected.contains(item.id)) continue;
            checkCancelled(control);
            try {
                if (control != null) control.progress(item, 0);
                if (StackStore.hasFingerprint(context, item.sha256)) {
                    retry(() -> { acknowledge(validated, item.id, control); return null; }, control);
                    continue;
                }
                File partial = StackStore.partialDownloadFile(context, item.id, item.size);
                long offset = partial.length();
                int retries = 0;
                while (offset < item.size) {
                    checkCancelled(control);
                    if (control != null) control.progress(item, offset);
                    int length = (int) Math.min(CHUNK_SIZE, item.size - offset);
                    try {
                        downloadRange(validated, item, partial, offset, length, control);
                        offset += length;
                        retries = 0;
                    } catch (IOException error) {
                        if (retries >= MAX_RETRIES || !retryable(error)) throw error;
                        waitForRetry(retries++, error, control);
                        offset = partial.length();
                    }
                }
                checkCancelled(control);
                boolean added = StackStore.finishDownloadedFile(context, partial,
                    new StackStore.DownloadMetadata(item.mimeType, item.name, item.size, item.sha256));
                if (added) StackBadge.update(context, StackStore.load(context).size());
                retry(() -> { acknowledge(validated, item.id, control); return null; }, control);
                received++;
            } catch (IOException exception) {
                checkCancelled(control);
                if (failure == null) failure = exception;
            }
        }
        if (failure != null) throw new IOException("수신 " + received + "개 · 일부 실패: " + failure.getMessage(), failure);
        return received;
    }

    private static void downloadRange(Pairing pairing, PendingItem item, File partial, long offset, int length,
        ReceiveControl control) throws IOException {
        HttpURLConnection content = open(pairing, "/v1/items/" + item.id + "/content");
        track(control, content);
        content.setRequestProperty("Range", "bytes=" + offset + "-" + (offset + length - 1));
        try {
            int status = content.getResponseCode();
            if (status != HttpURLConnection.HTTP_PARTIAL) {
                if (status < 200 || status >= 300) requireSuccess(content);
                throw new IOException("Mac 파일의 이어받기 응답이 올바르지 않습니다");
            }
            if (!("bytes " + offset + "-" + (offset + length - 1) + "/" + item.size)
                .equals(content.getHeaderField("Content-Range"))) {
                throw new IOException("Mac 파일의 이어받기 응답이 올바르지 않습니다");
            }
            try (InputStream input = content.getInputStream()) {
                StackStore.appendDownloadedRange(new StackStore.DownloadChunk(partial, offset, length), input);
            }
        } finally {
            content.disconnect();
        }
    }

    private static void acknowledge(Pairing pairing, String id, ReceiveControl control) throws IOException {
        checkCancelled(control);
        HttpURLConnection ack = open(pairing, "/v1/items/" + id + "/ack");
        track(control, ack);
        ack.setRequestMethod("POST");
        ack.setDoOutput(true);
        ack.setFixedLengthStreamingMode(0);
        try {
            ack.getOutputStream().close();
            requireSuccess(ack);
        } finally {
            ack.disconnect();
        }
    }

    private static void track(ReceiveControl control, HttpURLConnection connection) throws IOException {
        if (control != null) control.connection(connection);
        try { checkCancelled(control); }
        catch (IOException exception) { connection.disconnect(); throw exception; }
    }

    private static void checkCancelled(ReceiveControl control) throws IOException {
        if (Thread.currentThread().isInterrupted() || (control != null && control.cancelled())) throw new IOException("수신이 중지됐습니다");
    }

    private interface IOOperation<T> { T run() throws IOException; }

    private static <T> T retry(IOOperation<T> operation, ReceiveControl control) throws IOException {
        for (int retries = 0; ; retries++) {
            checkCancelled(control);
            try {
                return operation.run();
            } catch (IOException error) {
                if (retries >= MAX_RETRIES || !retryable(error)) throw error;
                waitForRetry(retries, error, control);
            }
        }
    }

    private static boolean retryable(IOException error) {
        if (error instanceof HttpFailure) {
            int status = ((HttpFailure) error).status;
            return status == 408 || status == 425 || status == 429 || status >= 500 && status <= 599;
        }
        for (Throwable cause = error; cause != null; cause = cause.getCause()) {
            if (cause instanceof SocketTimeoutException || cause instanceof SocketException
                || cause instanceof ConnectException || cause instanceof NoRouteToHostException
                || cause instanceof EOFException) return true;
        }
        return false;
    }

    private static void waitForRetry(int retryIndex, IOException error, ReceiveControl control) throws IOException {
        long remaining = retryDelayMillis(retryIndex, error);
        while (remaining > 0) {
            checkCancelled(control);
            long wait = Math.min(100, remaining);
            long start = System.nanoTime();
            try {
                Thread.sleep(wait);
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
                throw new IOException("전송이 중지됐습니다", exception);
            }
            remaining -= Math.max(1, (System.nanoTime() - start) / 1_000_000);
        }
        checkCancelled(control);
    }

    private static long retryDelayMillis(int retryIndex, IOException error) {
        if (error instanceof HttpFailure) {
            String value = ((HttpFailure) error).retryAfter;
            if (value != null) {
                try {
                    long seconds = Long.parseLong(value.trim());
                    return seconds <= 0 ? 0 : seconds > Long.MAX_VALUE / 1000 ? Long.MAX_VALUE : seconds * 1000;
                } catch (NumberFormatException ignored) {
                    try {
                        long delay = ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME)
                            .toInstant().toEpochMilli() - System.currentTimeMillis();
                        return Math.max(0, delay);
                    } catch (java.time.format.DateTimeParseException ignoredDate) { }
                }
            }
        }
        return 1000L << retryIndex;
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
        String retryAfter = connection.getHeaderField("Retry-After");
        String message = "Mac 연결에 실패했습니다 (HTTP " + status + ")";
        try (InputStream input = connection.getErrorStream()) {
            if (input != null) {
                byte[] body = readPrefix(input, 2048);
                JSONObject error = new JSONObject(new String(body, StandardCharsets.UTF_8));
                message = error.optString("error", message);
            }
        } catch (Exception ignored) { }
        throw new HttpFailure(status, retryAfter, message);
    }

    private static final class HttpFailure extends IOException {
        final int status;
        final String retryAfter;

        HttpFailure(int status, String retryAfter, String message) {
            super(message);
            this.status = status;
            this.retryAfter = retryAfter;
        }
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
