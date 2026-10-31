package com.pdg.sharestack;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.res.ColorStateList;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Typeface;
import android.media.ExifInterface;
import android.graphics.pdf.PdfRenderer;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.InsetDrawable;
import android.graphics.drawable.RippleDrawable;
import android.media.ThumbnailUtils;
import android.net.Uri;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.provider.MediaStore;
import android.text.TextUtils;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.DragEvent;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public final class MainActivity extends Activity {
    private static final String PREFS = "stack";
    private static final String VIEW_MODE = "view_mode";
    private static final String GRID_MODE = "grid";
    private static final String LIST_MODE = "list";
    private static final int BADGE_PERMISSION_REQUEST = 1002;
    private static final String SORT_MODE = "sort_mode";
    private static final int SORT_MANUAL = 0;
    private static final int SORT_NEWEST = 1;
    private static final int SORT_OLDEST = 2;
    private static final int BACKGROUND = 0xfff6f8fc;
    private static final int SURFACE = Color.WHITE;
    private static final int INK = 0xff172033;
    private static final int MUTED = 0xff667085;
    private static final int BORDER = 0xffe5eaf2;
    private static final int PRIMARY = 0xff2563eb;
    private static final int PRIMARY_DARK = 0xff174fc4;
    private static final int HEADER = 0xff17233f;
    private static final int HEADER_BUTTON = 0xff2b3a5d;
    private static final int DANGER = 0xffc93652;
    private final ArrayList<StackItem> items = new ArrayList<>();
    private final ArrayList<CheckBox> selections = new ArrayList<>();
    private final ArrayList<String> selectedItemIds = new ArrayList<>();
    private LinearLayout list;
    private Button shareButton;
    private Button deviceSendButton;
    private boolean deviceSending;
    private ImageButton macBridgeButton;
    private View macConnectionDot;
    private final Handler connectionHandler = new Handler(Looper.getMainLooper());
    private int connectionGeneration;
    private boolean connectionCheckingActive;
    private boolean wifiDiscoveryInProgress;
    private final Runnable checkMacConnection = this::checkMacConnection;
    private Button deleteButton;
    private Button selectionToggleButton;
    private boolean selectionsInitialized;
    private ScrollView scrollView;
    private volatile int renderGeneration;
    private final ArrayList<ThumbnailBinding> thumbnailBindings = new ArrayList<>();
    private final android.util.LruCache<String, Bitmap> thumbnailCache =
        new android.util.LruCache<String, Bitmap>((int) Math.min(24L * 1024 * 1024,
            Runtime.getRuntime().maxMemory() / 8)) {
            @Override protected int sizeOf(String key, Bitmap value) {
                return value.getByteCount();
            }
        };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        loadItems();
        buildUi();
        requestBadgePermissionIfNeeded();
        handlePairingIntent(getIntent());
        getIntent().setData(null);
    }

    @Override public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        reloadItems();
        requestBadgePermissionIfNeeded();
        handlePairingIntent(intent);
        intent.setData(null);
    }

    private void handlePairingIntent(Intent intent) {
        Uri pairing = intent == null ? null : intent.getData();
        if (pairing == null || !"sharestack".equals(pairing.getScheme()) || !"pair".equals(pairing.getHost())) return;
        String host = pairing.getQueryParameter("host");
        String token = pairing.getQueryParameter("token");
        String certificatePin = pairing.getQueryParameter("cert");
        MacBridgeClient.Pairing credentials = new MacBridgeClient.Pairing(host, token, certificatePin);
        if (!MacBridgeClient.isValidPairing(credentials)) {
            toast("잘못된 Share Stack 페어링 QR 코드입니다");
            return;
        }
        new AlertDialog.Builder(this)
            .setTitle("Share Stack 기기 연결")
            .setMessage(host + " 주소의 기기를 안전한 연결 정보에 추가할까요?")
            .setNegativeButton("취소", null)
            .setPositiveButton("연결", (dialog, which) -> getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putString(MacBridgeClient.HOST, host)
                .putString(MacBridgeClient.TOKEN, token)
                .putString(MacBridgeClient.TLS_PIN, certificatePin)
                .apply())
            .show();
    }

    @Override public void onResume() {
        super.onResume();
        getSharedPreferences(PREFS, MODE_PRIVATE).registerOnSharedPreferenceChangeListener(incomingListener);
        AIReadSync.preferences(this).registerOnSharedPreferenceChangeListener(aiReadListener);
        if (!AIReadSync.pending(this).isEmpty()) MacReceiveService.syncAI(this);
        if (getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(MacBridgeClient.AUTO_RECEIVE, false)
            || getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(MacBridgeClient.AUTO_SEND, false)) MacReceiveService.start(this, null);
        else MacReceiveService.checkOnOpen(this);
        if (list != null) reloadItems();
        connectionCheckingActive = true;
        refreshMacConnection();
    }

    private final SharedPreferences.OnSharedPreferenceChangeListener incomingListener = (preferences, key) -> {
        if (StackStore.ITEMS.equals(key)) runOnUiThread(() -> { if (list != null) reloadItems(); });
        if (MacBridgeClient.HOST.equals(key) || MacBridgeClient.TOKEN.equals(key) || MacBridgeClient.TLS_PIN.equals(key)) {
            runOnUiThread(this::refreshMacConnection);
        }
    };

    private final SharedPreferences.OnSharedPreferenceChangeListener aiReadListener = (preferences, key) -> {
        if (AIReadSync.INTENTS.equals(key)) runOnUiThread(() -> { if (list != null) render(); });
    };

    @Override public void onPause() {
        connectionCheckingActive = false;
        connectionGeneration++;
        connectionHandler.removeCallbacks(checkMacConnection);
        getSharedPreferences(PREFS, MODE_PRIVATE).unregisterOnSharedPreferenceChangeListener(incomingListener);
        AIReadSync.preferences(this).unregisterOnSharedPreferenceChangeListener(aiReadListener);
        super.onPause();
    }

    private void reloadItems() {
        Set<String> existingItemIds = new HashSet<>();
        for (StackItem item : items) existingItemIds.add(item.id);
        selectedItemIds.clear();
        for (CheckBox selection : selections) {
            if (selection.isChecked()) selectedItemIds.add((String) selection.getTag());
        }
        items.clear();
        loadItems();
        for (StackItem item : items) {
            if (!existingItemIds.contains(item.id) && !selectedItemIds.contains(item.id)) {
                selectedItemIds.add(item.id);
            }
        }
        render();
    }

    private void buildUi() {
        getWindow().setStatusBarColor(BACKGROUND);
        getWindow().setNavigationBarColor(BACKGROUND);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BACKGROUND);
        root.setPadding(dp(18), dp(16), dp(18), dp(16));
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(dp(18), dp(16) + insets.getSystemWindowInsetTop(), dp(18),
                dp(16) + insets.getSystemWindowInsetBottom());
            return insets;
        });

        LinearLayout toolbar = new LinearLayout(this);
        toolbar.setGravity(Gravity.CENTER_VERTICAL);
        macBridgeButton = new ImageButton(this);
        styleIconButton(macBridgeButton, R.drawable.ic_computer, "기기 연결");
        macBridgeButton.setOnClickListener(v -> showMacBridge());
        FrameLayout macBridge = new FrameLayout(this);
        macBridge.addView(macBridgeButton, new FrameLayout.LayoutParams(-1, -1));
        macConnectionDot = new View(this);
        macConnectionDot.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        FrameLayout.LayoutParams dotParams = new FrameLayout.LayoutParams(dp(12), dp(12), Gravity.TOP | Gravity.END);
        dotParams.setMargins(0, dp(3), dp(3), 0);
        macBridge.addView(macConnectionDot, dotParams);
        setMacConnectionState(false, false);
        ImageButton settings = new ImageButton(this);
        styleIconButton(settings, R.drawable.ic_settings, "설정");
        settings.setOnClickListener(v -> showSettings());
        selectionToggleButton = new Button(this);
        styleActionButton(selectionToggleButton, 0xffeef3ff, PRIMARY_DARK, 0, 14, 12);
        selectionToggleButton.setOnClickListener(v -> toggleAllItems());
        LinearLayout.LayoutParams selectionToggleParams = new LinearLayout.LayoutParams(dp(80), dp(40));
        selectionToggleParams.setMargins(0, 0, dp(4), 0);
        toolbar.addView(selectionToggleButton, selectionToggleParams);
        toolbar.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1));
        toolbar.addView(macBridge, new LinearLayout.LayoutParams(dp(48), dp(48)));
        toolbar.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1));
        toolbar.addView(settings, new LinearLayout.LayoutParams(dp(48), dp(48)));
        LinearLayout.LayoutParams toolbarParams = new LinearLayout.LayoutParams(-1, dp(48));
        toolbarParams.setMargins(0, 0, 0, dp(12));
        root.addView(toolbar, toolbarParams);

        scrollView = new ScrollView(this);
        scrollView.setClipToPadding(false);
        scrollView.setFillViewport(true);
        scrollView.setVerticalScrollBarEnabled(false);
        scrollView.setOnScrollChangeListener((view, scrollX, scrollY, oldScrollX, oldScrollY) ->
            updateVisibleThumbnails());
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        scrollView.addView(list);
        root.addView(scrollView, new LinearLayout.LayoutParams(-1, 0, 1));

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams actionsParams = new LinearLayout.LayoutParams(-1, -2);
        actionsParams.setMargins(0, dp(12), 0, 0);
        shareButton = new Button(this);
        styleActionButton(shareButton, PRIMARY, Color.WHITE, 0, 14, 12);
        shareButton.setOnClickListener(v -> shareSelected());
        deviceSendButton = new Button(this);
        deviceSendButton.setText("기기 전송");
        deviceSendButton.setContentDescription("선택 항목 기기로 전송");
        styleActionButton(deviceSendButton, 0xffeef3ff, PRIMARY_DARK, 0, 14, 12);
        deviceSendButton.setOnClickListener(v -> sendSelectedToDevice());
        deleteButton = new Button(this);
        deleteButton.setText("선택 삭제");
        styleActionButton(deleteButton, 0xfffff0f2, DANGER, 0, 14, 12);
        deleteButton.setOnClickListener(v -> clearSelected());
        LinearLayout.LayoutParams shareParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        shareParams.setMargins(0, 0, dp(2), 0);
        LinearLayout.LayoutParams copyParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        copyParams.setMargins(dp(2), 0, dp(2), 0);
        LinearLayout.LayoutParams clearParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        clearParams.setMargins(dp(2), 0, 0, 0);
        actions.addView(shareButton, shareParams);
        actions.addView(deviceSendButton, copyParams);
        actions.addView(deleteButton, clearParams);
        root.addView(actions, actionsParams);
        setContentView(root);
        render();
    }

    private void setMacConnectionState(boolean connected, boolean checking) {
        macConnectionDot.setBackground(roundedBackground(connected ? 0xff16a34a : 0xff98a2b3, Color.WHITE, 50));
        macBridgeButton.setContentDescription(connected ? "기기 연결됨" : checking ? "기기 연결 확인 중" : "기기 연결 안 됨");
    }

    private void refreshMacConnection() {
        connectionGeneration++;
        connectionHandler.removeCallbacks(checkMacConnection);
        if (!connectionCheckingActive) return;
        setMacConnectionState(false, true);
        connectionHandler.postDelayed(checkMacConnection, 150);
    }

    private void checkMacConnection() {
        if (!connectionCheckingActive) return;
        MacBridgeClient.Pairing pairing = MacBridgeClient.savedPairing(this);
        if (!MacBridgeClient.isValidPairing(pairing)) {
            setMacConnectionState(false, false);
            return;
        }
        int generation = connectionGeneration;
        new Thread(() -> {
            boolean connected;
            try {
                MacBridgeClient.checkConnection(this, pairing);
                connected = true;
            } catch (IOException | RuntimeException error) {
                connected = false;
            }
            boolean result = connected;
            connectionHandler.post(() -> {
                if (!connectionCheckingActive || generation != connectionGeneration) return;
                if (result) {
                    setMacConnectionState(true, false);
                    connectionHandler.postDelayed(checkMacConnection, 30000);
                } else {
                    reconnectDiscoveredDevice(pairing, generation);
                }
            });
        }).start();
    }

    private void reconnectDiscoveredDevice(MacBridgeClient.Pairing pairing, int generation) {
        discoverWifiDevices(null, null, found -> {
            if (!connectionCheckingActive || generation != connectionGeneration) return;
            new Thread(() -> {
                String verifiedHost = null;
                for (String address : new HashSet<>(found.values())) {
                    if (address.equals(pairing.host)) continue;
                    try {
                        MacBridgeClient.checkConnection(this, new MacBridgeClient.Pairing(address, pairing.token, pairing.certificatePin));
                        verifiedHost = address;
                        break;
                    } catch (IOException | RuntimeException ignored) { }
                }
                String host = verifiedHost;
                connectionHandler.post(() -> {
                    if (!connectionCheckingActive || generation != connectionGeneration) return;
                    if (host != null && StackStore.updateVerifiedHost(this, pairing, host)) {
                        MacReceiveService.checkOnOpen(this);
                    } else {
                        setMacConnectionState(false, false);
                        connectionHandler.postDelayed(checkMacConnection, 30000);
                    }
                });
            }, "share-stack-reconnect").start();
        });
    }

    private void showMacBridge() {
        SharedPreferences preferences = getSharedPreferences(PREFS, MODE_PRIVATE);
        Dialog dialog = new Dialog(this);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(18), dp(18), dp(18), dp(14));
        panel.setBackground(roundedBackground(SURFACE, BORDER, 20));

        TextView title = new TextView(this);
        title.setText("기기 연결");
        title.setTextSize(20);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setTextColor(INK);
        panel.addView(title);

        TextView guidance = new TextView(this);
        guidance.setText("같은 Wi-Fi에서 기기를 찾거나 연결할 기기의 QR 코드를 스캔하세요. 현재 Mac 연결을 지원합니다.");
        guidance.setTextSize(13);
        guidance.setTextColor(MUTED);
        LinearLayout.LayoutParams guidanceParams = new LinearLayout.LayoutParams(-1, -2);
        guidanceParams.setMargins(0, dp(6), 0, dp(12));
        panel.addView(guidance, guidanceParams);

        Button discover = new Button(this);
        discover.setText("같은 Wi-Fi에서 기기 찾기");
        styleActionButton(discover, 0xffeef3ff, PRIMARY_DARK, 0, 12, 13);
        LinearLayout.LayoutParams discoverParams = new LinearLayout.LayoutParams(-1, dp(42));
        discoverParams.setMargins(0, dp(4), 0, dp(4));
        panel.addView(discover, discoverParams);

        Button manualToggle = new Button(this);
        manualToggle.setText("수동 연결 정보 보기");
        styleActionButton(manualToggle, SURFACE, INK, 0, 12, 13);
        panel.addView(manualToggle, new LinearLayout.LayoutParams(-1, dp(42)));
        LinearLayout manual = new LinearLayout(this);
        manual.setOrientation(LinearLayout.VERTICAL);
        manual.setVisibility(View.GONE);
        panel.addView(manual);
        manualToggle.setOnClickListener(v -> {
            boolean show = manual.getVisibility() != View.VISIBLE;
            manual.setVisibility(show ? View.VISIBLE : View.GONE);
            manualToggle.setText(show ? "수동 연결 정보 닫기" : "수동 연결 정보 보기");
        });

        EditText host = new EditText(this);
        host.setSingleLine(true);
        host.setTextSize(14);
        host.setHint("기기 Wi-Fi 또는 Tailscale IPv4");
        host.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        host.setText(preferences.getString(MacBridgeClient.HOST, ""));
        String[] shownHost = { host.getText().toString() };
        manual.addView(host, new LinearLayout.LayoutParams(-1, dp(48)));

        EditText token = new EditText(this);
        token.setSingleLine(true);
        token.setTextSize(14);
        token.setHint("짝 토큰");
        token.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        token.setText(preferences.getString(MacBridgeClient.TOKEN, ""));
        manual.addView(token, new LinearLayout.LayoutParams(-1, dp(48)));

        EditText certificatePin = new EditText(this);
        certificatePin.setSingleLine(true);
        certificatePin.setTextSize(12);
        certificatePin.setHint("TLS 지문 (QR 연결 권장)");
        certificatePin.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        certificatePin.setText(preferences.getString(MacBridgeClient.TLS_PIN, ""));
        manual.addView(certificatePin, new LinearLayout.LayoutParams(-1, dp(48)));

        TextView selectedDevice = new TextView(this);
        selectedDevice.setTextSize(14);
        selectedDevice.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        selectedDevice.setTextColor(PRIMARY_DARK);
        selectedDevice.setPadding(dp(14), dp(12), dp(14), dp(12));
        selectedDevice.setBackground(roundedBackground(0xffeef3ff, 0xffcbdcff, 12));
        LinearLayout.LayoutParams selectedParams = new LinearLayout.LayoutParams(-1, -2);
        selectedParams.setMargins(0, dp(8), 0, dp(4));
        panel.addView(selectedDevice, selectedParams);
        Runnable updateSelectedDevice = () -> {
            String address = host.getText().toString().trim();
            boolean paired = MacBridgeClient.isValidPairing(new MacBridgeClient.Pairing(address,
                token.getText().toString().trim(), certificatePin.getText().toString().trim()));
            selectedDevice.setText(address.isEmpty() ? "선택한 기기 없음"
                : "선택한 기기 · " + address + "\n" + (paired ? "✓ 연결 정보 준비됨" : "QR 코드 연결 필요"));
        };
        TextWatcher selectionWatcher = new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) { updateSelectedDevice.run(); }
            @Override public void afterTextChanged(Editable s) { }
        };
        host.addTextChangedListener(selectionWatcher);
        token.addTextChangedListener(selectionWatcher);
        certificatePin.addTextChangedListener(selectionWatcher);
        updateSelectedDevice.run();

        TextView status = new TextView(this);
        status.setText(preferences.getString(MacBridgeClient.RECEIVE_STATUS, "파일과 텍스트를 양방향으로 전송합니다."));
        status.setTextSize(12);
        status.setTextColor(MUTED);
        LinearLayout.LayoutParams statusParams = new LinearLayout.LayoutParams(-1, -2);
        statusParams.setMargins(0, dp(8), 0, dp(10));
        panel.addView(status, statusParams);

        CheckBox automatic = new CheckBox(this);
        automatic.setText("Mac → Android 자동 수신");
        automatic.setChecked(preferences.getBoolean(MacBridgeClient.AUTO_RECEIVE, false));
        panel.addView(automatic);
        automatic.setOnClickListener(v -> {
            if (!automatic.isChecked()) {
                preferences.edit().putBoolean(MacBridgeClient.AUTO_RECEIVE, false).apply();
                MacReceiveService.start(this, null);
                return;
            }
            MacBridgeClient.Pairing pairing = saveMacPairing(host, token, certificatePin);
            if (!MacBridgeClient.isValidPairing(pairing)) {
                automatic.setChecked(false);
                status.setText("먼저 기기의 QR 코드로 연결하세요.");
                return;
            }
            if (android.os.Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                automatic.setChecked(false);
                requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, BADGE_PERMISSION_REQUEST);
                status.setText("알림을 허용한 뒤 자동 수신을 켜세요.");
                return;
            }
            preferences.edit().putBoolean(MacBridgeClient.AUTO_RECEIVE, true).apply();
            MacReceiveService.start(this, null);
        });
        CheckBox automaticSend = new CheckBox(this);
        automaticSend.setText("Android → Mac 자동 전송");
        automaticSend.setChecked(preferences.getBoolean(MacBridgeClient.AUTO_SEND, false));
        panel.addView(automaticSend);
        automaticSend.setOnClickListener(v -> {
            if (automaticSend.isChecked()) {
                MacBridgeClient.Pairing pairing = saveMacPairing(host, token, certificatePin);
                if (!MacBridgeClient.isValidPairing(pairing)) {
                    automaticSend.setChecked(false);
                    status.setText("먼저 기기의 QR 코드로 연결하세요.");
                    return;
                }
                if (android.os.Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    automaticSend.setChecked(false);
                    requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, BADGE_PERMISSION_REQUEST);
                    status.setText("알림을 허용한 뒤 자동 전송을 켜세요.");
                    return;
                }
            }
            preferences.edit().putBoolean(MacBridgeClient.AUTO_SEND, automaticSend.isChecked()).apply();
            MacReceiveService.start(this, null);
        });
        SharedPreferences.OnSharedPreferenceChangeListener receiveListener = (prefs, key) -> runOnUiThread(() -> {
            if (MacBridgeClient.HOST.equals(key)) {
                String savedHost = prefs.getString(MacBridgeClient.HOST, "");
                if (host.getText().toString().equals(shownHost[0])) host.setText(savedHost);
                shownHost[0] = savedHost;
            }
            automatic.setChecked(prefs.getBoolean(MacBridgeClient.AUTO_RECEIVE, false));
            automaticSend.setChecked(prefs.getBoolean(MacBridgeClient.AUTO_SEND, false));
            if (MacBridgeClient.RECEIVE_STATUS.equals(key)) status.setText(prefs.getString(key, ""));
        });
        preferences.registerOnSharedPreferenceChangeListener(receiveListener);
        dialog.setOnDismissListener(ignored -> preferences.unregisterOnSharedPreferenceChangeListener(receiveListener));

        LinearLayout actions = new LinearLayout(this);
        Button send = new Button(this);
        send.setText("선택 보내기");
        styleActionButton(send, PRIMARY, Color.WHITE, 0, 14, 13);
        Button receive = new Button(this);
        receive.setText("기기 대기 파일");
        styleActionButton(receive, 0xffeef3ff, PRIMARY_DARK, 0, 14, 13);
        LinearLayout.LayoutParams actionParams = new LinearLayout.LayoutParams(0, dp(46), 1);
        actionParams.setMargins(0, 0, dp(4), 0);
        actions.addView(send, actionParams);
        LinearLayout.LayoutParams receiveParams = new LinearLayout.LayoutParams(0, dp(46), 1);
        receiveParams.setMargins(dp(4), 0, 0, 0);
        actions.addView(receive, receiveParams);
        panel.addView(actions);

        LinearLayout footer = new LinearLayout(this);
        footer.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        Button save = new Button(this);
        save.setText("저장");
        styleActionButton(save, 0xffeef3ff, PRIMARY_DARK, 0, 14, 13);
        Button close = new Button(this);
        close.setText("닫기");
        styleActionButton(close, SURFACE, INK, 0, 14, 13);
        footer.addView(save, new LinearLayout.LayoutParams(dp(88), dp(42)));
        footer.addView(close, new LinearLayout.LayoutParams(dp(76), dp(42)));
        LinearLayout.LayoutParams footerParams = new LinearLayout.LayoutParams(-1, -2);
        footerParams.setMargins(0, dp(6), 0, 0);
        panel.addView(footer, footerParams);

        save.setOnClickListener(v -> {
            preferences.edit()
                .putString(MacBridgeClient.HOST, host.getText().toString().trim())
                .putString(MacBridgeClient.TOKEN, token.getText().toString().trim())
                .putString(MacBridgeClient.TLS_PIN, certificatePin.getText().toString().trim().toLowerCase(Locale.ROOT))
                .apply();
            status.setText("연결 정보를 저장했습니다.");
        });
        close.setOnClickListener(v -> dialog.dismiss());
        discover.setOnClickListener(v -> discoverMacOnWifi(host, token, certificatePin, status, discover));
        send.setOnClickListener(v -> runMacTransfer(host, token, certificatePin, status, send, receive, true));
        receive.setOnClickListener(v -> showPendingMacFiles(saveMacPairing(host, token, certificatePin), status, receive));

        ScrollView scroll = new ScrollView(this);
        scroll.addView(panel);
        dialog.setContentView(scroll);
        Window window = dialog.getWindow();
        if (window != null) {
            window.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            window.setLayout(Math.min(getResources().getDisplayMetrics().widthPixels - dp(36), dp(420)), -2);
        }
        dialog.show();
        if (dialog.getWindow() != null) {
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.getWindow().setLayout(Math.min(getResources().getDisplayMetrics().widthPixels - dp(36), dp(420)), -2);
        }
    }

    private void discoverMacOnWifi(EditText hostField, EditText tokenField, EditText pinField, TextView status, Button button) {
        discoverWifiDevices(status, button, found -> {
            ArrayList<String> labels = new ArrayList<>(found.keySet());
            ArrayList<String> addresses = new ArrayList<>(found.values());
            if (addresses.isEmpty()) {
                status.setText("기기를 찾지 못했습니다. 같은 Wi-Fi인지 확인하세요.");
                return;
            }
            new AlertDialog.Builder(this)
                .setTitle("연결할 기기 선택")
                .setSingleChoiceItems(labels.toArray(new String[0]), addresses.indexOf(hostField.getText().toString().trim()), (dialog, which) -> {
                    String address = addresses.get(which);
                    if (!address.equals(hostField.getText().toString().trim())) {
                        tokenField.setText("");
                        pinField.setText("");
                    }
                    hostField.setText(address);
                    status.setText(MacBridgeClient.isValidPairing(new MacBridgeClient.Pairing(address,
                        tokenField.getText().toString().trim(), pinField.getText().toString().trim()))
                        ? "기기가 검색되었고 연결 정보가 준비되어 있습니다." : "기기를 찾았습니다. 기기의 QR 코드를 스캔해 연결하세요.");
                    dialog.dismiss();
                })
                .setNegativeButton("취소", null)
                .show();
        });
    }

    private void discoverWifiDevices(TextView status, Button button, java.util.function.Consumer<Map<String, String>> completed) {
        if (wifiDiscoveryInProgress) {
            if (status != null) status.setText("기기 검색이 진행 중입니다. 잠시 후 다시 시도하세요.");
            else completed.accept(java.util.Collections.emptyMap());
            return;
        }
        NsdManager manager = (NsdManager) getSystemService(Context.NSD_SERVICE);
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (manager == null || wifi == null) {
            if (status != null) status.setText("Wi-Fi 기기 검색을 사용할 수 없습니다.");
            completed.accept(java.util.Collections.emptyMap());
            return;
        }
        if (button != null) button.setEnabled(false);
        WifiManager.MulticastLock multicastLock = wifi.createMulticastLock("share-stack-discovery");
        multicastLock.setReferenceCounted(false);
        try {
            multicastLock.acquire();
        } catch (RuntimeException exception) {
            if (status != null) status.setText("Wi-Fi 기기 검색 권한이 필요합니다.");
            if (button != null) button.setEnabled(true);
            completed.accept(java.util.Collections.emptyMap());
            return;
        }

        wifiDiscoveryInProgress = true;
        Handler handler = new Handler(Looper.getMainLooper());
        Map<String, String> found = new LinkedHashMap<>();
        boolean[] finished = { false };
        boolean[] resolving = { false };
        java.util.ArrayDeque<NsdServiceInfo> pending = new java.util.ArrayDeque<>();
        Runnable[] resolveNext = new Runnable[1];
        resolveNext[0] = () -> {
            if (finished[0] || resolving[0] || pending.isEmpty()) return;
            resolving[0] = true;
            NsdServiceInfo service = pending.removeFirst();
            try {
                manager.resolveService(service, new NsdManager.ResolveListener() {
                    @Override public void onResolveFailed(NsdServiceInfo failedService, int errorCode) {
                        handler.post(() -> { resolving[0] = false; resolveNext[0].run(); });
                    }
                    @Override public void onServiceResolved(NsdServiceInfo resolved) {
                        handler.post(() -> {
                            resolving[0] = false;
                            String address = resolved.getHost() == null ? null : resolved.getHost().getHostAddress();
                            if (!finished[0] && resolved.getPort() == MacBridgeClient.PORT
                                && MacBridgeClient.isSupportedHost(address)) {
                                found.put(resolved.getServiceName() + " · " + address, address);
                            }
                            resolveNext[0].run();
                        });
                    }
                });
            } catch (RuntimeException ignored) {
                resolving[0] = false;
                resolveNext[0].run();
            }
        };
        NsdManager.DiscoveryListener[] listenerHolder = new NsdManager.DiscoveryListener[1];
        Runnable[] finishHolder = new Runnable[1];
        NsdManager.DiscoveryListener listener = new NsdManager.DiscoveryListener() {
            @Override public void onDiscoveryStarted(String serviceType) {
                if (status != null) handler.post(() -> status.setText("같은 Wi-Fi에서 기기 검색 중…"));
            }

            @Override public void onServiceFound(NsdServiceInfo service) {
                if (service.getServiceType() == null || !service.getServiceType().startsWith("_sharestack._tcp")) return;
                handler.post(() -> { if (!finished[0]) { pending.addLast(service); resolveNext[0].run(); } });
            }

            @Override public void onServiceLost(NsdServiceInfo service) { }
            @Override public void onDiscoveryStopped(String serviceType) { }
            @Override public void onStartDiscoveryFailed(String serviceType, int errorCode) {
                if (finishHolder[0] != null) handler.post(finishHolder[0]);
            }
            @Override public void onStopDiscoveryFailed(String serviceType, int errorCode) { }
        };
        listenerHolder[0] = listener;
        finishHolder[0] = () -> {
            if (finished[0]) return;
            finished[0] = true;
            try {
                manager.stopServiceDiscovery(listenerHolder[0]);
            } catch (IllegalArgumentException ignored) { }
            if (multicastLock.isHeld()) multicastLock.release();
            wifiDiscoveryInProgress = false;
            if (button != null) button.setEnabled(true);
            completed.accept(found);
        };
        try {
            manager.discoverServices("_sharestack._tcp.", NsdManager.PROTOCOL_DNS_SD, listener);
            handler.postDelayed(finishHolder[0], 6000);
        } catch (RuntimeException exception) {
            finishHolder[0].run();
            if (status != null) status.setText("기기 검색을 시작하지 못했습니다.");
        }
    }

    private MacBridgeClient.Pairing saveMacPairing(EditText host, EditText token, EditText pin) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putString(MacBridgeClient.HOST, host.getText().toString().trim())
            .putString(MacBridgeClient.TOKEN, token.getText().toString().trim())
            .putString(MacBridgeClient.TLS_PIN, pin.getText().toString().trim().toLowerCase(Locale.ROOT)).apply();
        return MacBridgeClient.savedPairing(this);
    }

    private void showPendingMacFiles(MacBridgeClient.Pairing pairing, TextView status, Button button) {
        button.setEnabled(false);
        status.setText("대기 파일 확인 중…");
        new Thread(() -> {
            try {
                java.util.List<MacBridgeClient.PendingItem> pending = MacBridgeClient.pending(this, pairing);
                runOnUiThread(() -> {
                    button.setEnabled(true);
                    if (isFinishing() || isDestroyed()) return;
                    status.setText("대기 " + pending.size() + "개");
                    if (pending.isEmpty()) return;
                    String[] labels = new String[pending.size()];
                    boolean[] checked = new boolean[pending.size()];
                    for (int i = 0; i < pending.size(); i++) labels[i] = pending.get(i).name + " · " + android.text.format.Formatter.formatFileSize(this, pending.get(i).size);
                    AlertDialog chooser = new AlertDialog.Builder(this).setTitle("기기 대기 파일")
                        .setMultiChoiceItems(labels, checked, (dialog, index, selected) -> {
                            checked[index] = selected;
                            boolean any = false;
                            for (boolean value : checked) any |= value;
                            ((AlertDialog) dialog).getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(any);
                        })
                        .setPositiveButton("선택 수신", (dialog, which) -> {
                            ArrayList<String> ids = new ArrayList<>();
                            for (int i = 0; i < checked.length; i++) if (checked[i]) ids.add(pending.get(i).id);
                            MacReceiveService.start(this, ids);
                        })
                        .setNeutralButton("전체 수신", (dialog, which) -> {
                            ArrayList<String> ids = new ArrayList<>();
                            for (MacBridgeClient.PendingItem item : pending) ids.add(item.id);
                            MacReceiveService.start(this, ids);
                        }).setNegativeButton("닫기", null).create();
                    chooser.show();
                    chooser.getButton(AlertDialog.BUTTON_POSITIVE).setEnabled(false);
                });
            } catch (Exception error) {
                runOnUiThread(() -> { button.setEnabled(true); status.setText("조회 실패: " + error.getMessage()); });
            }
        }, "mac-pending").start();
    }

    private void runMacTransfer(EditText host, EditText token, EditText certificatePin, TextView status,
        Button send, Button receive, boolean sending) {
        String address = host.getText().toString().trim();
        String secret = token.getText().toString().trim();
        String pin = certificatePin.getText().toString().trim().toLowerCase(Locale.ROOT);
        MacBridgeClient.Pairing pairing = new MacBridgeClient.Pairing(address, secret, pin);
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putString(MacBridgeClient.HOST, address)
            .putString(MacBridgeClient.TOKEN, secret)
            .putString(MacBridgeClient.TLS_PIN, pin)
            .apply();
        ArrayList<StackItem> selectedItems = new ArrayList<>();
        if (sending) selectedItems.addAll(selected());
        if (sending && selectedItems.isEmpty()) {
            status.setText("먼저 보낼 항목을 선택하세요.");
            return;
        }
        send.setEnabled(false);
        receive.setEnabled(false);
        status.setText(sending ? "기기로 전송 중…" : "기기에서 항목 확인 중…");
        Thread worker = new Thread(() -> {
            try {
                int count = sending
                    ? MacBridgeClient.send(this, pairing, selectedItems)
                    : MacBridgeClient.receive(this, pairing);
                runOnUiThread(() -> {
                    send.setEnabled(true);
                    receive.setEnabled(true);
                    status.setText(sending
                        ? count + "개 항목을 기기로 보냈습니다."
                        : count == 0 ? "받을 항목이 없습니다." : count + "개 항목을 기기에서 받았습니다.");
                    if (!sending && count > 0) reloadItems();
                });
            } catch (Exception exception) {
                runOnUiThread(() -> {
                    send.setEnabled(true);
                    receive.setEnabled(true);
                    status.setText(exception.getMessage() == null ? "전송에 실패했습니다." : exception.getMessage());
                });
            }
        }, "share-stack-mac-transfer");
        worker.start();
    }

    private void showSettings() {
        Dialog dialog = new Dialog(this);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(18), dp(18), dp(18), dp(12));
        panel.setBackground(roundedBackground(SURFACE, BORDER, 20));
        TextView title = new TextView(this);
        title.setText("설정");
        title.setTextSize(20);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setTextColor(INK);
        panel.addView(title);
        addSettingsSection(panel, "공유 및 알림");
        int[] expiryDays = {getSharedPreferences(PREFS, MODE_PRIVATE)
            .getInt(StackStore.AUTO_EXPIRY_DAYS, 0)};
        int[] sortMode = {getSharedPreferences(PREFS, MODE_PRIVATE)
            .getInt(SORT_MODE, SORT_MANUAL)};
        String[] viewMode = {getSharedPreferences(PREFS, MODE_PRIVATE)
            .getString(VIEW_MODE, GRID_MODE)};
        CheckBox clearAfterShare = new CheckBox(this);
        clearAfterShare.setText("공유 후 스택 비우기");
        clearAfterShare.setChecked(getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(StackStore.CLEAR_STACK_AFTER_SHARE, false));
        clearAfterShare.setTextSize(14);
        clearAfterShare.setTextColor(INK);
        clearAfterShare.setButtonTintList(new ColorStateList(new int[][] {new int[] {android.R.attr.state_checked}, new int[] {}}, new int[] {PRIMARY, 0xffa2adbd}));
        LinearLayout option = new LinearLayout(this);
        option.setGravity(Gravity.CENTER_VERTICAL);
        option.setPadding(dp(2), 0, 0, 0);
        option.addView(clearAfterShare, new LinearLayout.LayoutParams(-1, dp(44)));
        panel.addView(option, new LinearLayout.LayoutParams(-1, dp(44)));
        addSettingsDivider(panel);
        CheckBox saveUrlWithMedia = new CheckBox(this);
        saveUrlWithMedia.setText("이미지 공유 시 URL도 저장");
        saveUrlWithMedia.setChecked(getSharedPreferences(PREFS, MODE_PRIVATE)
            .getBoolean(StackStore.SAVE_URL_WITH_MEDIA, true));
        saveUrlWithMedia.setTextSize(14);
        saveUrlWithMedia.setTextColor(INK);
        saveUrlWithMedia.setButtonTintList(new ColorStateList(new int[][] {new int[] {android.R.attr.state_checked}, new int[] {}}, new int[] {PRIMARY, 0xffa2adbd}));
        LinearLayout urlOption = new LinearLayout(this);
        urlOption.setGravity(Gravity.CENTER_VERTICAL);
        urlOption.setPadding(dp(2), 0, 0, 0);
        urlOption.addView(saveUrlWithMedia, new LinearLayout.LayoutParams(-1, dp(44)));
        panel.addView(urlOption, new LinearLayout.LayoutParams(-1, dp(44)));
        addSettingsDivider(panel);
        CheckBox openAfterReceiving = new CheckBox(this);
        openAfterReceiving.setText("공유받은 뒤 앱 열기");
        openAfterReceiving.setChecked(getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(StackStore.OPEN_AFTER_RECEIVING, false));
        openAfterReceiving.setTextSize(14);
        openAfterReceiving.setTextColor(INK);
        openAfterReceiving.setButtonTintList(new ColorStateList(new int[][] {new int[] {android.R.attr.state_checked}, new int[] {}}, new int[] {PRIMARY, 0xffa2adbd}));
        LinearLayout receiveOption = new LinearLayout(this);
        receiveOption.setGravity(Gravity.CENTER_VERTICAL);
        receiveOption.setPadding(dp(2), 0, 0, 0);
        receiveOption.addView(openAfterReceiving, new LinearLayout.LayoutParams(-1, dp(44)));
        LinearLayout.LayoutParams receiveOptionParams = new LinearLayout.LayoutParams(-1, dp(44));
        receiveOptionParams.setMargins(0, 0, 0, 0);
        panel.addView(receiveOption, receiveOptionParams);
        addSettingsDivider(panel);
        CheckBox showNotificationShareAction = new CheckBox(this);
        showNotificationShareAction.setText("알림을 누르면 전체 공유");
        showNotificationShareAction.setChecked(getSharedPreferences(PREFS, MODE_PRIVATE)
            .getBoolean(StackStore.SHOW_NOTIFICATION_SHARE_ACTION, false));
        showNotificationShareAction.setTextSize(14);
        showNotificationShareAction.setTextColor(INK);
        showNotificationShareAction.setButtonTintList(new ColorStateList(new int[][] {new int[] {android.R.attr.state_checked}, new int[] {}}, new int[] {PRIMARY, 0xffa2adbd}));
        LinearLayout notificationOption = new LinearLayout(this);
        notificationOption.setGravity(Gravity.CENTER_VERTICAL);
        notificationOption.setPadding(dp(2), 0, 0, 0);
        notificationOption.addView(showNotificationShareAction, new LinearLayout.LayoutParams(-1, dp(44)));
        LinearLayout.LayoutParams notificationOptionParams = new LinearLayout.LayoutParams(-1, dp(44));
        notificationOptionParams.setMargins(0, 0, 0, 0);
        panel.addView(notificationOption, notificationOptionParams);
        addSettingsDivider(panel);
        CheckBox keepStackNotification = new CheckBox(this);
        keepStackNotification.setText("스택 알림 고정");
        keepStackNotification.setChecked(getSharedPreferences(PREFS, MODE_PRIVATE)
            .getBoolean(StackStore.KEEP_STACK_NOTIFICATION, true));
        keepStackNotification.setTextSize(14);
        keepStackNotification.setTextColor(INK);
        keepStackNotification.setButtonTintList(new ColorStateList(new int[][] {new int[] {android.R.attr.state_checked}, new int[] {}}, new int[] {PRIMARY, 0xffa2adbd}));
        LinearLayout keepNotificationOption = new LinearLayout(this);
        keepNotificationOption.setGravity(Gravity.CENTER_VERTICAL);
        keepNotificationOption.setPadding(dp(2), 0, 0, 0);
        keepNotificationOption.addView(keepStackNotification, new LinearLayout.LayoutParams(-1, dp(44)));
        LinearLayout.LayoutParams keepNotificationOptionParams = new LinearLayout.LayoutParams(-1, dp(44));
        keepNotificationOptionParams.setMargins(0, 0, 0, 0);
        panel.addView(keepNotificationOption, keepNotificationOptionParams);
        addSettingsSection(panel, "보기 및 정리");
        Button sorting = new Button(this);
        stylePlainSettingsButton(sorting);
        updateSortingButton(sorting, sortMode[0]);
        sorting.setOnClickListener(view -> {
            String[] choices = {"수동 순서", "최신순", "오래된순"};
            new AlertDialog.Builder(this)
                .setTitle("스택 정렬")
                .setSingleChoiceItems(choices, sortMode[0], (picker, which) -> {
                    sortMode[0] = which;
                    updateSortingButton(sorting, sortMode[0]);
                    picker.dismiss();
                })
                .show();
        });
        LinearLayout.LayoutParams sortingParams = new LinearLayout.LayoutParams(-1, dp(44));
        sortingParams.setMargins(0, 0, 0, 0);
        panel.addView(sorting, sortingParams);
        addSettingsDivider(panel);
        Button viewModeButton = new Button(this);
        stylePlainSettingsButton(viewModeButton);
        updateViewModeButton(viewModeButton, viewMode[0]);
        viewModeButton.setOnClickListener(view -> {
            String[] choices = {"썸네일형", "목록형"};
            int checked = LIST_MODE.equals(viewMode[0]) ? 1 : 0;
            new AlertDialog.Builder(this)
                .setTitle("보기 방식")
                .setSingleChoiceItems(choices, checked, (picker, which) -> {
                    viewMode[0] = which == 1 ? LIST_MODE : GRID_MODE;
                    updateViewModeButton(viewModeButton, viewMode[0]);
                    getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                        .putString(VIEW_MODE, viewMode[0])
                        .apply();
                    render();
                    picker.dismiss();
                })
                .show();
        });
        LinearLayout.LayoutParams viewModeParams = new LinearLayout.LayoutParams(-1, dp(44));
        viewModeParams.setMargins(0, 0, 0, 0);
        panel.addView(viewModeButton, viewModeParams);
        addSettingsDivider(panel);
        Button expiry = new Button(this);
        stylePlainSettingsButton(expiry);
        updateExpiryButton(expiry, expiryDays[0]);
        expiry.setOnClickListener(view -> {
            String[] choices = {"사용 안 함", "1일 뒤", "7일 뒤", "30일 뒤"};
            int[] values = {0, 1, 7, 30};
            int checked = 0;
            for (int index = 0; index < values.length; index++) {
                if (values[index] == expiryDays[0]) checked = index;
            }
            new AlertDialog.Builder(this)
                .setTitle("스택 자동 만료")
                .setSingleChoiceItems(choices, checked, (picker, which) -> {
                    expiryDays[0] = values[which];
                    updateExpiryButton(expiry, expiryDays[0]);
                    picker.dismiss();
                })
                .show();
        });
        LinearLayout.LayoutParams expiryParams = new LinearLayout.LayoutParams(-1, dp(44));
        expiryParams.setMargins(0, 0, 0, 0);
        panel.addView(expiry, expiryParams);
        LinearLayout buttons = new LinearLayout(this);
        buttons.setGravity(Gravity.CENTER_VERTICAL);
        buttons.setPadding(0, dp(14), 0, 0);
        Button cancel = new Button(this);
        cancel.setText("취소");
        styleCompactSettingsButton(cancel, 0xfff7f9fc, PRIMARY_DARK, BORDER, 12, 14);
        cancel.setOnClickListener(v -> dialog.dismiss());
        Button save = new Button(this);
        save.setText("저장");
        styleCompactSettingsButton(save, PRIMARY, Color.WHITE, 0, 12, 14);
        save.setOnClickListener(v -> {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putBoolean(StackStore.CLEAR_STACK_AFTER_SHARE, clearAfterShare.isChecked())
                .putBoolean(StackStore.SAVE_URL_WITH_MEDIA, saveUrlWithMedia.isChecked())
                .putBoolean(StackStore.OPEN_AFTER_RECEIVING, openAfterReceiving.isChecked())
                .putBoolean(StackStore.SHOW_NOTIFICATION_SHARE_ACTION, showNotificationShareAction.isChecked())
                .putBoolean(StackStore.KEEP_STACK_NOTIFICATION, keepStackNotification.isChecked())
                .putInt(StackStore.AUTO_EXPIRY_DAYS, expiryDays[0])
                .putInt(SORT_MODE, sortMode[0])
                .putString(VIEW_MODE, viewMode[0])
                .apply();
            reloadItems();
            updateStackBadge();
            dialog.dismiss();
        });
        LinearLayout.LayoutParams cancelParams = new LinearLayout.LayoutParams(0, dp(44), 1);
        cancelParams.setMargins(0, 0, dp(4), 0);
        LinearLayout.LayoutParams saveParams = new LinearLayout.LayoutParams(0, dp(44), 1);
        saveParams.setMargins(dp(4), 0, 0, 0);
        buttons.addView(cancel, cancelParams);
        buttons.addView(save, saveParams);
        panel.addView(buttons);
        dialog.setContentView(panel);
        dialog.show();
        if (dialog.getWindow() != null) {
            dialog.getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            dialog.getWindow().setLayout(-1, -2);
        }
    }

    private void updateExpiryButton(Button button, int days) {
        button.setText(days <= 0 ? "자동 만료 · 사용 안 함" : "자동 만료 · " + days + "일 뒤");
    }

    private void updateSortingButton(Button button, int mode) {
        button.setText(mode == SORT_NEWEST ? "정렬 · 최신순"
            : mode == SORT_OLDEST ? "정렬 · 오래된순" : "정렬 · 수동 순서");
    }

    private void updateViewModeButton(Button button, String mode) {
        button.setText(LIST_MODE.equals(mode) ? "보기 방식 · 목록형" : "보기 방식 · 썸네일형");
    }

    @SuppressWarnings("deprecation")
    private boolean handleIncoming(Intent intent) {
        if (!isIncomingShare(intent)) return false;
        boolean added = false;
        String text = intent.getStringExtra(Intent.EXTRA_TEXT);
        if (text != null && !text.isEmpty()) { addText(text); added = true; }
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
        if (intent.getClipData() != null) for (int i = 0; i < intent.getClipData().getItemCount(); i++) {
            Uri uri = intent.getClipData().getItemAt(i).getUri(); if (uri != null && !uris.contains(uri)) uris.add(uri);
        }
        for (Uri uri : uris) { if (addUri(uri, intent.getType())) added = true; }
        if (added) { saveItems(); render(); intent.setAction(null); }
        return added;
    }

    private boolean isIncomingShare(Intent intent) {
        return intent != null && (Intent.ACTION_SEND.equals(intent.getAction()) || Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction()));
    }

    private boolean shouldOpenAfterReceiving() {
        return getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(StackStore.OPEN_AFTER_RECEIVING, false);
    }

    private void addText(String text) {
        String id = UUID.randomUUID().toString() + ".txt";
        writeBytes(id, text.getBytes(StandardCharsets.UTF_8));
        items.add(new StackItem(id, "text/plain", shorten(text)));
    }

    private boolean addUri(Uri uri, String fallbackType) {
        String id = UUID.randomUUID().toString();
        try (InputStream input = getContentResolver().openInputStream(uri); FileOutputStream output = new FileOutputStream(itemFile(id))) {
            if (input == null) return false;
            byte[] buffer = new byte[8192]; int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            String type = getContentResolver().getType(uri); if (type == null) type = fallbackType == null ? "application/octet-stream" : fallbackType;
            items.add(new StackItem(id, type, displayName(uri)));
            return true;
        } catch (IOException ignored) { return false; }
    }

    private void writeBytes(String id, byte[] data) {
        try (FileOutputStream output = new FileOutputStream(itemFile(id))) { output.write(data); } catch (IOException ignored) { }
    }

    private String displayName(Uri uri) {
        try (Cursor cursor = getContentResolver().query(uri, null, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) { int column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME); if (column >= 0) return cursor.getString(column); }
        } catch (Exception ignored) { }
        return uri.getLastPathSegment() == null ? "공유 항목" : uri.getLastPathSegment();
    }

    private void toggleAllItems() {
        boolean allSelected = !items.isEmpty();
        for (StackItem item : items) {
            if (!isItemSelected(item)) {
                allSelected = false;
                break;
            }
        }
        boolean selectAll = !allSelected;
        selectedItemIds.clear();
        if (selectAll) {
            for (StackItem item : items) selectedItemIds.add(item.id);
        }
        for (CheckBox selection : selections) selection.setChecked(selectAll);
        selectionsInitialized = true;
        render();
    }

    private void render() {
        if (list == null) return;
        renderGeneration++;
        thumbnailBindings.clear();
        if (selectionsInitialized && selections.size() == items.size()) {
            selectedItemIds.clear();
            for (CheckBox selection : selections) {
                if (selection.isChecked()) selectedItemIds.add((String) selection.getTag());
            }
        }
        list.removeAllViews(); selections.clear();
        if (items.isEmpty()) {
            LinearLayout empty = new LinearLayout(this);
            empty.setOrientation(LinearLayout.VERTICAL);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(dp(24), dp(36), dp(24), dp(36));
            empty.setBackground(roundedBackground(SURFACE, BORDER, 20));
            TextView emptyTitle = new TextView(this);
            emptyTitle.setText("아직 쌓인 항목이 없어요");
            emptyTitle.setTextSize(17);
            emptyTitle.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
            emptyTitle.setTextColor(INK);
            empty.addView(emptyTitle);
            list.addView(empty, new LinearLayout.LayoutParams(-1, -2));
            selectionsInitialized = true;
            updateSelectionState();
            updateStackBadge();
            return;
        }
        TextView aiGuide = new TextView(this);
        aiGuide.setText("체크한 파일만 AI가 읽을 수 있습니다.");
        aiGuide.setTextSize(12);
        aiGuide.setTextColor(MUTED);
        aiGuide.setPadding(0, 0, 0, dp(8));
        list.addView(aiGuide);
        if (isListMode()) {
            for (StackItem item : items) addListItem(item);
        } else {
            ArrayList<StackItem> compactItems = new ArrayList<>();
            ArrayList<StackItem> thumbnailItems = new ArrayList<>();
            for (StackItem item : items) {
                if (isThumbnailCapable(item)) thumbnailItems.add(item);
                else compactItems.add(item);
            }
            for (StackItem item : compactItems) addCompactGridItem(item);
            LinearLayout row = null;
            for (int index = 0; index < thumbnailItems.size(); index++) {
                if (index % 2 == 0) {
                    row = new LinearLayout(this);
                    row.setOrientation(LinearLayout.HORIZONTAL);
                    row.setBaselineAligned(false);
                    LinearLayout.LayoutParams rowParams = new LinearLayout.LayoutParams(-1, dp(146));
                    rowParams.setMargins(0, 0, 0, dp(10));
                    list.addView(row, rowParams);
                }
                addItemCard(row, thumbnailItems.get(index), index % 2 == 0);
            }
            if (thumbnailItems.size() % 2 != 0 && row != null) {
                row.addView(new View(this), new LinearLayout.LayoutParams(0, -1, 1));
            }
        }
        selectionsInitialized = true;
        updateSelectionState();
        updateStackBadge();
        if (scrollView != null) scrollView.post(this::updateVisibleThumbnails);
    }

    private void addItemCard(LinearLayout row, StackItem item, boolean firstInRow) {
        FrameLayout card = new FrameLayout(this);
        applyAIReadBackground(card, item, 18);
        card.setElevation(dp(2));
        card.setClipToOutline(true);

        View preview = previewFor(item);
        preview.setOnClickListener(v -> showItemDetails(item));
        card.addView(preview, new FrameLayout.LayoutParams(-1, -1));
        CheckBox box = newSelectionBox(item);
        card.addView(box, new FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP | Gravity.END));
        TextView typeChip = new TextView(this);
        typeChip.setText(contentTypeLabel(item.mimeType));
        typeChip.setTextSize(11);
        typeChip.setTextColor(INK);
        typeChip.setGravity(Gravity.CENTER);
        typeChip.setPadding(dp(8), 0, dp(8), 0);
        typeChip.setBackground(roundedBackground(0xa0ffffff, 0, 50));
        FrameLayout.LayoutParams typeChipParams = new FrameLayout.LayoutParams(-2, dp(28), Gravity.TOP | Gravity.START);
        typeChipParams.setMargins(dp(8), dp(8), 0, 0);
        card.addView(typeChip, typeChipParams);

        LinearLayout details = new LinearLayout(this);
        details.setOrientation(LinearLayout.VERTICAL);
        details.setGravity(Gravity.CENTER_VERTICAL);
        details.setPadding(dp(10), dp(4), dp(10), dp(4));
        details.setBackgroundColor(0xe0ffffff);
        TextView name = new TextView(this);
        name.setText(item.name);
        name.setTextSize(14);
        name.setTextColor(INK);
        name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        name.setMaxLines(1);
        name.setSingleLine(true);
        name.setEllipsize(TextUtils.TruncateAt.END);
        applyLockIndicator(name, item);
        details.addView(aiReadNameRow(item, name));
        card.addView(details, new FrameLayout.LayoutParams(-1, dp(48), Gravity.BOTTOM));
        card.setOnClickListener(v -> box.setChecked(!box.isChecked()));
        enableReorder(card, item);

        LinearLayout.LayoutParams cardParams = new LinearLayout.LayoutParams(0, -1, 1);
        cardParams.setMargins(firstInRow ? 0 : dp(5), 0, firstInRow ? dp(5) : 0, 0);
        row.addView(card, cardParams);
    }

    private void addCompactGridItem(StackItem item) {
        FrameLayout compact = new FrameLayout(this);
        applyAIReadBackground(compact, item, 14);
        compact.setElevation(dp(1));
        TextView name = new TextView(this);
        name.setText(item.name);
        name.setTextSize(15);
        name.setTextColor(INK);
        name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        name.setSingleLine(true);
        name.setEllipsize(TextUtils.TruncateAt.END);
        name.setGravity(Gravity.CENTER_VERTICAL);
        name.setPadding(dp(14), 0, dp(48), 0);
        applyLockIndicator(name, item);
        FrameLayout.LayoutParams nameParams = new FrameLayout.LayoutParams(-1, -1);
        nameParams.setMargins(dp(10), 0, dp(48), 0);
        name.setPadding(0, 0, 0, 0);
        compact.addView(aiReadNameRow(item, name), nameParams);
        CheckBox box = newSelectionBox(item);
        compact.addView(box, new FrameLayout.LayoutParams(dp(48), dp(48), Gravity.CENTER_VERTICAL | Gravity.END));
        compact.setOnClickListener(v -> box.setChecked(!box.isChecked()));
        enableReorder(compact, item);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(54));
        params.setMargins(0, 0, 0, dp(8));
        list.addView(compact, params);
    }

    private void addListItem(StackItem item) {
        FrameLayout card = new FrameLayout(this);
        card.setPadding(dp(8), dp(8), dp(12), dp(8));
        applyAIReadBackground(card, item, 18);
        card.setElevation(dp(2));

        LinearLayout content = new LinearLayout(this);
        content.setGravity(Gravity.CENTER_VERTICAL);

        FrameLayout previewArea = new FrameLayout(this);
        previewArea.setBackground(roundedBackground(0xfff1f3f4, 0, 12));
        previewArea.setClipToOutline(true);
        View preview = previewFor(item);
        preview.setOnClickListener(v -> showItemDetails(item));
        previewArea.addView(preview, new FrameLayout.LayoutParams(-1, -1));
        CheckBox box = newSelectionBox(item);
        content.addView(previewArea, new LinearLayout.LayoutParams(dp(72), dp(76)));

        LinearLayout details = new LinearLayout(this);
        details.setOrientation(LinearLayout.VERTICAL);
        details.setGravity(Gravity.CENTER_VERTICAL);
        details.setPadding(dp(12), 0, dp(48), 0);
        TextView name = new TextView(this);
        name.setText(item.name);
        name.setTextSize(16);
        name.setTextColor(INK);
        name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        name.setSingleLine(true);
        name.setEllipsize(TextUtils.TruncateAt.END);
        applyLockIndicator(name, item);
        TextView type = new TextView(this);
        type.setText(contentTypeLabel(item.mimeType));
        type.setTextSize(13);
        type.setTextColor(MUTED);
        type.setPadding(0, dp(4), 0, 0);
        details.addView(aiReadNameRow(item, name));
        details.addView(type);
        content.addView(details, new LinearLayout.LayoutParams(0, -1, 1));
        card.addView(content, new FrameLayout.LayoutParams(-1, -1));
        FrameLayout.LayoutParams boxParams = new FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP | Gravity.END);
        boxParams.setMargins(0, -dp(12), -dp(12), 0);
        card.addView(box, boxParams);
        card.setOnClickListener(v -> box.setChecked(!box.isChecked()));
        enableReorder(card, item);

        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(92));
        params.setMargins(0, 0, 0, dp(10));
        list.addView(card, params);
    }

    private LinearLayout aiReadNameRow(StackItem item, TextView name) {
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.addView(name, new LinearLayout.LayoutParams(0, -2, 1));
        AIReadIntent intent = AIReadSync.get(this, item.id);
        CheckBox ai = new CheckBox(this);
        ai.setTextSize(10);
        ai.setTextColor(MUTED);
        ai.setMinHeight(dp(48));
        ai.setPadding(0, 0, 0, 0);
        ai.setButtonTintList(ColorStateList.valueOf(PRIMARY));
        ai.setChecked(intent != null && intent.allowed);
        String status = intent == null ? "" : intent.status().replace("AI 읽기 ", "").replace(" · 재시도 대기", " · 재시도").replace("동기화 대기", "대기");
        ai.setText(intent == null ? "AI 허용" : "AI 허용\n" + status);
        ai.setMaxLines(2);
        ai.setEllipsize(TextUtils.TruncateAt.END);
        ai.setContentDescription(item.name + " · AI 읽기 허용" + (intent == null ? "" : " · " + intent.status() + " · " + intent.error));
        row.addView(ai, new LinearLayout.LayoutParams(dp(100), dp(48)));
        ai.setOnCheckedChangeListener((button, checked) -> {
            try {
                AIReadSync.choose(this, item.id, checked);
                MacReceiveService.syncAI(this);
            } catch (Exception error) { toast(error.getMessage()); }
            render();
        });
        return row;
    }

    private void applyAIReadBackground(FrameLayout card, StackItem item, int radius) {
        android.graphics.drawable.Drawable base = roundedBackground(SURFACE, BORDER, radius);
        AIReadIntent intent = AIReadSync.get(this, item.id);
        if (intent != null && intent.allowed && intent.pending()) {
            android.graphics.drawable.ClipDrawable fill = new android.graphics.drawable.ClipDrawable(
                roundedBackground(0xffe8f0ff, 0, radius), Gravity.START, android.graphics.drawable.ClipDrawable.HORIZONTAL);
            android.graphics.drawable.LayerDrawable layers = new android.graphics.drawable.LayerDrawable(
                new android.graphics.drawable.Drawable[]{base, fill});
            card.setBackground(layers);
            fill.setLevel(Math.max(300, intent.progress * 100));
            if (isThumbnailCapable(item) && !isListMode()) {
                android.graphics.drawable.ClipDrawable overlay = new android.graphics.drawable.ClipDrawable(
                    roundedBackground(0x402563eb, 0, radius), Gravity.START, android.graphics.drawable.ClipDrawable.HORIZONTAL);
                card.setForeground(overlay);
                overlay.setLevel(Math.max(300, intent.progress * 100));
            }
        } else { card.setBackground(base); card.setForeground(null); }
    }

    private CheckBox newSelectionBox(StackItem item) {
        CheckBox box = new CheckBox(this);
        box.setTag(item.id);
        box.setChecked(!selectionsInitialized || selectedItemIds.contains(item.id));
        box.setButtonDrawable(null);
        box.setTextColor(Color.WHITE);
        box.setTextSize(16);
        box.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        box.setGravity(Gravity.CENTER);
        box.setIncludeFontPadding(false);
        applySelectionStyle(box, box.isChecked());
        box.setContentDescription(item.name + " 선택");
        box.setOnCheckedChangeListener((button, checked) -> {
            applySelectionStyle(box, checked);
            updateSelectionState();
        });
        selections.add(box);
        return box;
    }

    private void enableReorder(View surface, StackItem item) {
        surface.setOnLongClickListener(view -> {
            ClipData data = ClipData.newPlainText("Share Stack item", item.id);
            view.startDragAndDrop(data, new View.DragShadowBuilder(view), item.id, 0);
            return true;
        });
        surface.setOnDragListener((view, event) -> {
            String draggedId = event.getLocalState() instanceof String ? (String) event.getLocalState() : null;
            if (draggedId == null || draggedId.equals(item.id)) return false;
            if (event.getAction() == DragEvent.ACTION_DRAG_ENTERED) {
                view.setAlpha(0.62f);
                return true;
            }
            if (event.getAction() == DragEvent.ACTION_DRAG_EXITED || event.getAction() == DragEvent.ACTION_DRAG_ENDED) {
                view.setAlpha(1f);
                return true;
            }
            if (event.getAction() == DragEvent.ACTION_DROP) {
                view.setAlpha(1f);
                reorderItem(draggedId, item.id);
                return true;
            }
            return true;
        });
    }

    private void reorderItem(String draggedId, String targetId) {
        int from = -1;
        int to = -1;
        for (int index = 0; index < items.size(); index++) {
            if (draggedId.equals(items.get(index).id)) from = index;
            if (targetId.equals(items.get(index).id)) to = index;
        }
        if (from < 0 || to < 0 || from == to) return;
        StackItem dragged = items.remove(from);
        if (from < to) to--;
        items.add(to, dragged);
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putInt(SORT_MODE, SORT_MANUAL).apply();
        saveItems();
        render();
    }

    private void showItemDetails(StackItem item) {
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(20), dp(8), dp(20), 0);
        View preview = detailPreviewFor(item);
        panel.addView(preview, new LinearLayout.LayoutParams(-1, dp(260)));
        TextView name = new TextView(this);
        name.setText(item.name);
        name.setTextColor(INK);
        name.setTextSize(17);
        name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        name.setPadding(0, dp(16), 0, dp(4));
        panel.addView(name);
        TextView type = new TextView(this);
        type.setText(contentTypeLabel(item.mimeType));
        type.setTextColor(MUTED);
        type.setTextSize(14);
        panel.addView(type);
        if ("text/plain".equals(item.mimeType)) {
            TextView text = new TextView(this);
            text.setText(readText(item));
            text.setTextColor(INK);
            text.setTextSize(15);
            text.setPadding(0, dp(12), 0, 0);
            ScrollView textScroll = new ScrollView(this);
            textScroll.addView(text);
            panel.addView(textScroll, new LinearLayout.LayoutParams(-1, dp(180)));
        }
        AlertDialog dialog = new AlertDialog.Builder(this)
            .setTitle("항목 미리보기")
            .setView(panel)
            .setNegativeButton("삭제", null)
            .setNeutralButton(item.locked ? "잠금 해제" : "잠금 보관", null)
            .setPositiveButton("닫기", null)
            .create();
        dialog.setOnShowListener(ignored -> {
            dialog.getButton(AlertDialog.BUTTON_NEGATIVE).setOnClickListener(view -> new AlertDialog.Builder(this)
                .setMessage("이 항목을 삭제할까요?")
                .setNegativeButton("취소", null)
                .setPositiveButton("삭제", (confirm, which) -> {
                    itemFile(item.id).delete();
                    items.remove(item);
                    selectedItemIds.remove(item.id);
                    saveItems();
                    dialog.dismiss();
                    render();
                })
                .show());
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(view -> {
                setItemLocked(item, !item.locked);
                dialog.dismiss();
            });
        });
        dialog.show();
    }

    private void setItemLocked(StackItem item, boolean locked) {
        for (int index = 0; index < items.size(); index++) {
            if (items.get(index).id.equals(item.id)) {
                items.set(index, item.withLocked(locked));
                saveItems();
                render();
                toast(locked ? "항목을 잠금 보관했습니다" : "항목 잠금을 해제했습니다");
                return;
            }
        }
    }

    private String readText(StackItem item) {
        try (FileInputStream input = new FileInputStream(itemFile(item.id))) {
            return new String(readAll(input), StandardCharsets.UTF_8);
        } catch (IOException ignored) {
            return "텍스트를 불러올 수 없습니다";
        }
    }

    private View detailPreviewFor(StackItem item) {
        if (!isThumbnailCapable(item)) return previewTile(item);
        ImageView image = new ImageView(this);
        image.setScaleType(ImageView.ScaleType.FIT_CENTER);
        image.setBackgroundColor(0xfff1f3f4);
        Bitmap cached = thumbnailCache.get(item.id);
        if (cached != null) {
            image.setImageBitmap(cached);
        } else {
            BackgroundWork.run(() -> thumbnail(item), (bitmap, error) -> {
                if (bitmap == null) return;
                thumbnailCache.put(item.id, bitmap);
                image.setImageBitmap(bitmap);
            });
        }
        return image;
    }

    private boolean isThumbnailCapable(StackItem item) {
        return item.mimeType.startsWith("image/") || item.mimeType.startsWith("video/") || "application/pdf".equals(item.mimeType);
    }

    private View previewFor(StackItem item) {
        if (!isThumbnailCapable(item)) return previewTile(item);
        FrameLayout frame = new FrameLayout(this);
        ImageView image = new ImageView(this);
        image.setScaleType(ImageView.ScaleType.CENTER_CROP);
        image.setBackground(roundedBackground(0xfff1f3f4, 0));
        frame.addView(image, new FrameLayout.LayoutParams(-1, -1));
        ThumbnailBinding binding = new ThumbnailBinding(item, image);
        thumbnailBindings.add(binding);
        Bitmap cached = thumbnailCache.get(item.id);
        if (cached != null) {
            image.setImageBitmap(cached);
            binding.loaded = true;
        }
        if (item.mimeType.startsWith("video/")) {
            TextView play = new TextView(this);
            play.setText("▶");
            play.setTextColor(Color.WHITE);
            play.setTextSize(22);
            play.setGravity(Gravity.CENTER);
            play.setBackground(roundedBackground(0x99000000, 0));
            FrameLayout.LayoutParams playParams = new FrameLayout.LayoutParams(dp(38), dp(38), Gravity.CENTER);
            frame.addView(play, playParams);
        }
        return frame;
    }

    private Bitmap thumbnail(StackItem item) {
        File file = itemFile(item.id);
        if (item.mimeType.startsWith("image/")) return imageThumbnail(file);
        if (item.mimeType.startsWith("video/")) return videoThumbnail(file);
        if ("application/pdf".equals(item.mimeType)) return pdfThumbnail(file);
        return null;
    }

    private void updateVisibleThumbnails() {
        if (scrollView == null || thumbnailBindings.isEmpty()) return;
        int[] scrollLocation = new int[2];
        scrollView.getLocationInWindow(scrollLocation);
        int top = scrollLocation[1] - dp(240);
        int bottom = scrollLocation[1] + scrollView.getHeight() + dp(240);
        int[] location = new int[2];
        for (ThumbnailBinding binding : thumbnailBindings) {
            binding.image.getLocationInWindow(location);
            boolean visible = location[1] + binding.image.getHeight() >= top && location[1] <= bottom;
            binding.visible = visible;
            if (!visible) {
                if (binding.loaded) {
                    binding.image.setImageDrawable(null);
                    binding.loaded = false;
                }
                continue;
            }
            if (binding.loaded || binding.loading) continue;
            Bitmap cached = thumbnailCache.get(binding.item.id);
            if (cached != null) {
                binding.image.setImageBitmap(cached);
                binding.loaded = true;
                continue;
            }
            binding.loading = true;
            int generation = renderGeneration;
            BackgroundWork.run(() -> generation == renderGeneration ? thumbnail(binding.item) : null,
                (bitmap, error) -> {
                    binding.loading = false;
                    if (generation != renderGeneration || bitmap == null) return;
                    thumbnailCache.put(binding.item.id, bitmap);
                    if (binding.visible) {
                        binding.image.setImageBitmap(bitmap);
                        binding.loaded = true;
                    }
                });
        }
    }

    private static final class ThumbnailBinding {
        final StackItem item;
        final ImageView image;
        boolean loaded;
        boolean loading;
        volatile boolean visible;

        ThumbnailBinding(StackItem item, ImageView image) {
            this.item = item;
            this.image = image;
        }
    }

    private View previewTile(StackItem item) {
        TextView tile = new TextView(this);
        tile.setGravity(Gravity.CENTER);
        tile.setPadding(dp(8), dp(6), dp(8), dp(6));
        tile.setTextColor(INK);
        tile.setTextSize("text/plain".equals(item.mimeType) ? 12 : 15);
        tile.setBackground(roundedBackground(previewColor(item.mimeType), 0));
        if ("text/plain".equals(item.mimeType)) {
            tile.setText(textPreview(item));
            tile.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
            tile.setMaxLines(4);
            tile.setEllipsize(TextUtils.TruncateAt.END);
        } else {
            tile.setText(contentTypeLabel(item.mimeType));
        }
        return tile;
    }

    private Bitmap imageThumbnail(File file) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(file.getAbsolutePath(), bounds);
        int sample = 1;
        while (bounds.outWidth / sample > 336 || bounds.outHeight / sample > 252) sample *= 2;
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = sample;
        Bitmap bitmap = BitmapFactory.decodeFile(file.getAbsolutePath(), options);
        if (bitmap == null) return null;
        try {
            int orientation = new ExifInterface(file.getAbsolutePath()).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
            Matrix matrix = new Matrix();
            if (orientation == ExifInterface.ORIENTATION_ROTATE_90) matrix.postRotate(90);
            else if (orientation == ExifInterface.ORIENTATION_ROTATE_180) matrix.postRotate(180);
            else if (orientation == ExifInterface.ORIENTATION_ROTATE_270) matrix.postRotate(270);
            if (!matrix.isIdentity()) return Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, true);
        } catch (IOException ignored) { }
        return bitmap;
    }

    @SuppressWarnings("deprecation")
    private Bitmap videoThumbnail(File file) {
        try {
            return ThumbnailUtils.createVideoThumbnail(file.getAbsolutePath(), MediaStore.Video.Thumbnails.MINI_KIND);
        } catch (Exception ignored) {
            return null;
        }
    }

    private Bitmap pdfThumbnail(File file) {
        try (ParcelFileDescriptor descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
             PdfRenderer renderer = new PdfRenderer(descriptor)) {
            if (renderer.getPageCount() == 0) return null;
            PdfRenderer.Page page = renderer.openPage(0);
            try {
                int width = 336;
                int height = Math.max(180, Math.round(width * (float) page.getHeight() / page.getWidth()));
                Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
                bitmap.eraseColor(Color.WHITE);
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                return bitmap;
            } finally {
                page.close();
            }
        } catch (IOException | SecurityException ignored) {
            return null;
        }
    }

    private String textPreview(StackItem item) {
        try (FileInputStream input = new FileInputStream(itemFile(item.id))) {
            byte[] bytes = new byte[240];
            int length = input.read(bytes);
            if (length > 0) return new String(bytes, 0, length, StandardCharsets.UTF_8).trim();
        } catch (IOException ignored) { }
        return "텍스트";
    }

    private int previewColor(String mimeType) {
        if ("text/plain".equals(mimeType)) return 0xfffff8e1;
        if ("application/pdf".equals(mimeType)) return 0xffffebee;
        if (mimeType.startsWith("video/")) return 0xffe8f0fe;
        return 0xfff1f3f4;
    }

    private GradientDrawable roundedBackground(int color, int strokeColor) {
        return roundedBackground(color, strokeColor, 12);
    }

    private GradientDrawable roundedBackground(int color, int strokeColor, int radius) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(color);
        background.setCornerRadius(dp(radius));
        if (strokeColor != 0) background.setStroke(dp(1), strokeColor);
        return background;
    }

    private void styleButton(Button button, int fill, int textColor, int stroke, int radius, int textSize) {
        button.setAllCaps(false);
        button.setTextSize(textSize);
        button.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        button.setTextColor(textColor);
        button.setGravity(Gravity.CENTER);
        button.setPadding(dp(12), 0, dp(12), 0);
        button.setMinWidth(0);
        button.setMinimumWidth(0);
        button.setMinimumHeight(dp(48));
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(0x26000000), roundedBackground(fill, stroke, radius), null));
    }

    private void styleCompactSettingsButton(Button button, int fill, int textColor, int stroke, int radius, int textSize) {
        styleButton(button, fill, textColor, stroke, radius, textSize);
        button.setMinimumHeight(0);
        button.setMinHeight(0);
        button.setPadding(dp(10), 0, dp(10), 0);
        button.setTypeface(Typeface.DEFAULT);
        button.setStateListAnimator(null);
        button.setElevation(0);
        button.setTranslationZ(0);
    }

    private void stylePlainSettingsButton(Button button) {
        button.setAllCaps(false);
        button.setTextSize(14);
        button.setTypeface(Typeface.DEFAULT);
        button.setTextColor(INK);
        button.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
        button.setPadding(dp(2), 0, dp(2), 0);
        button.setMinWidth(0);
        button.setMinimumWidth(0);
        button.setMinimumHeight(0);
        button.setMinHeight(0);
        button.setStateListAnimator(null);
        button.setElevation(0);
        button.setTranslationZ(0);
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(0x18000000),
            new ColorDrawable(Color.TRANSPARENT), null));
    }

    private void addSettingsSection(LinearLayout panel, String text) {
        TextView section = new TextView(this);
        section.setText(text);
        section.setTextSize(12);
        section.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        section.setTextColor(MUTED);
        section.setGravity(Gravity.BOTTOM);
        section.setPadding(dp(2), dp(14), 0, dp(4));
        panel.addView(section, new LinearLayout.LayoutParams(-1, dp(36)));
    }

    private void addSettingsDivider(LinearLayout panel) {
        View divider = new View(this);
        divider.setBackgroundColor(BORDER);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(1));
        params.setMargins(dp(2), 0, 0, 0);
        panel.addView(divider, params);
    }

    private void styleIconButton(ImageButton button, int icon, String description) {
        button.setImageResource(icon);
        button.setContentDescription(description);
        button.setScaleType(ImageView.ScaleType.CENTER);
        button.setPadding(dp(12), dp(12), dp(12), dp(12));
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(0x26000000),
            roundedBackground(0xffedf2f8, 0, 14), null));
    }

    private void styleActionButton(Button button, int fill, int textColor, int stroke, int radius, int textSize) {
        styleButton(button, fill, textColor, stroke, radius, textSize);
        button.setStateListAnimator(null);
        button.setElevation(0);
        button.setTranslationZ(0);
        button.setSingleLine(true);
        button.setMaxLines(1);
        button.setEllipsize(TextUtils.TruncateAt.END);
        button.setPadding(dp(5), 0, dp(5), 0);
    }

    private void applySelectionStyle(CheckBox box, boolean selected) {
        box.setText(selected ? "✓" : "");
        InsetDrawable marker = new InsetDrawable(
            roundedBackground(selected ? PRIMARY : SURFACE, selected ? 0 : 0xffaab6c8, 6), dp(14));
        box.setBackground(new RippleDrawable(ColorStateList.valueOf(0x22000000),
            marker, null));
    }

    private void updateSelectionState() {
        int selectedCount = 0;
        for (StackItem item : items) if (isItemSelected(item)) selectedCount++;
        if (selectionToggleButton != null) {
            boolean hasItems = !items.isEmpty();
            boolean allSelected = hasItems && selectedCount == items.size();
            selectionToggleButton.setEnabled(hasItems);
            selectionToggleButton.setText(allSelected ? "전체 해제" : "전체 선택");
            styleActionButton(selectionToggleButton,
                hasItems ? (allSelected ? 0xfff2f4f7 : 0xffeef3ff) : 0xffeff2f6,
                hasItems ? (allSelected ? MUTED : PRIMARY_DARK) : 0xff66758d, 0, 14, 12);
        }
        if (shareButton != null) {
            boolean canShare = selectedCount > 0;
            shareButton.setEnabled(canShare);
            styleActionButton(shareButton, canShare ? PRIMARY : 0xffd6e2fb, canShare ? Color.WHITE : 0xff58709a, 0, 14, 12);
            shareButton.setAlpha(1f);
            shareButton.setText("선택공유");
        }
        if (deleteButton != null) {
            boolean canDelete = selectedCount > 0;
            deleteButton.setEnabled(canDelete);
            styleActionButton(deleteButton, canDelete ? 0xfffff0f2 : 0xfff7eef0, canDelete ? DANGER : 0xff99636f, 0, 14, 12);
            deleteButton.setAlpha(1f);
        }
        if (deviceSendButton != null) {
            boolean canSend = selectedCount > 0 && !deviceSending;
            deviceSendButton.setEnabled(canSend);
            deviceSendButton.setText(deviceSending ? "전송 중" : "기기 전송");
            styleActionButton(deviceSendButton, canSend ? 0xffeef3ff : 0xffeff2f6,
                canSend ? PRIMARY_DARK : 0xff66758d, 0, 14, 12);
        }
    }

    private boolean isListMode() {
        return LIST_MODE.equals(getSharedPreferences(PREFS, MODE_PRIVATE).getString(VIEW_MODE, GRID_MODE));
    }

    private void requestBadgePermissionIfNeeded() {
        if (items.isEmpty()) return;
        if (android.os.Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, BADGE_PERMISSION_REQUEST);
        } else {
            updateStackBadge();
        }
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == BADGE_PERMISSION_REQUEST && grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            updateStackBadge();
        }
    }

    private void updateStackBadge() {
        StackBadge.update(this, items.size());
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private List<StackItem> selected() {
        ArrayList<StackItem> result = new ArrayList<>();
        for (StackItem item : items) if (isItemSelected(item)) result.add(item);
        return result;
    }

    private boolean isItemSelected(StackItem item) {
        for (CheckBox selection : selections) {
            if (item.id.equals(selection.getTag())) return selection.isChecked();
        }
        return selectedItemIds.contains(item.id);
    }

    private void sendSelectedToDevice() {
        MacBridgeClient.Pairing pairing = MacBridgeClient.savedPairing(this);
        if (!MacBridgeClient.isValidPairing(pairing)) {
            toast("먼저 기기를 연결하세요");
            showMacBridge();
            return;
        }
        ArrayList<StackItem> chosen = new ArrayList<>(selected());
        if (chosen.isEmpty() || deviceSending) return;
        deviceSending = true;
        render();
        new Thread(() -> {
            try {
                int count = MacBridgeClient.send(this, pairing, chosen);
                runOnUiThread(() -> { deviceSending = false; render(); toast(count + "개 항목을 기기로 보냈습니다"); });
            } catch (Exception error) {
                runOnUiThread(() -> { deviceSending = false; render(); toast("전송 실패: " + error.getMessage()); });
            }
        }, "share-stack-device-send").start();
    }

    private void shareSelected() {
        List<StackItem> selected = selected();
        if (selected.isEmpty()) { toast("공유할 항목을 선택하세요"); return; }
        int fileCount = 0;
        for (StackItem item : selected) if (!"text/plain".equals(item.mimeType)) fileCount++;
        if (fileCount > 1) {
            boolean hasText = false;
            for (StackItem item : selected) if ("text/plain".equals(item.mimeType)) { hasText = true; break; }
            new AlertDialog.Builder(this)
                .setTitle("공유 방식")
                .setMessage(hasText
                    ? "파일과 텍스트를 공유 화면으로 보냅니다. 대상 앱이 여러 파일을 받지 못하면 ZIP으로 공유하세요."
                    : "한번에 공유가 권장됩니다. 대상 앱이 여러 파일을 받지 못하면 ZIP으로 공유하세요.")
                .setPositiveButton("한번에 공유", (dialog, which) -> shareItems(selected, false))
                .setNeutralButton("ZIP으로 공유", (dialog, which) -> shareItems(selected, true))
                .setNegativeButton("취소", null)
                .show();
            return;
        }
        shareItems(selected, false);
    }

    private void shareItems(List<StackItem> selected, boolean zipFiles) {
        final boolean clearAfterShare = getSharedPreferences(PREFS, MODE_PRIVATE)
            .getBoolean(StackStore.CLEAR_STACK_AFTER_SHARE, false);
        AlertDialog progress = new AlertDialog.Builder(this)
            .setMessage("공유 준비 중…")
            .setCancelable(false)
            .create();
        progress.show();
        BackgroundWork.run(() -> prepareShare(selected, zipFiles, clearAfterShare), (payload, error) -> {
            if (isFinishing() || isDestroyed()) { progress.dismiss(); return; }
            progress.dismiss();
            if (error != null || payload == null) {
                toast("공유 파일을 준비할 수 없습니다");
                return;
            }
            launchShare(payload);
        });
    }

    private PreparedShare prepareShare(List<StackItem> selected, boolean zipFiles, boolean clearAfterShare)
        throws IOException {
        String text = selectedText(selected);
        ArrayList<StackItem> sharedFiles = new ArrayList<>();
        for (StackItem item : selected) if (!"text/plain".equals(item.mimeType)) sharedFiles.add(item);
        ArrayList<Uri> uris = new ArrayList<>();
        String sendType = "text/plain";
        if (!sharedFiles.isEmpty()) {
            if (zipFiles && sharedFiles.size() > 1) {
                uris.add(createZipForSharing(sharedFiles));
                sendType = "application/zip";
            } else {
                for (StackItem item : sharedFiles) {
                    String id = clearAfterShare ? copyForSharing(item) : item.id;
                    uris.add(contentUri(clearAfterShare ? "shared/" : "", id, item.name, item.mimeType));
                }
                sendType = commonType(sharedFiles);
            }
        }
        return new PreparedShare(uris, sendType, text, selected, clearAfterShare);
    }

    private void launchShare(PreparedShare payload) {
        if (payload.uris.isEmpty() && payload.text.isEmpty()) { toast("공유할 내용을 찾을 수 없습니다"); return; }
        Intent send = new Intent(payload.uris.size() <= 1 ? Intent.ACTION_SEND : Intent.ACTION_SEND_MULTIPLE);
        send.setType(payload.sendType);
        if (!payload.uris.isEmpty()) {
            ClipData clipData = ClipData.newRawUri("Share Stack items", payload.uris.get(0));
            for (int index = 1; index < payload.uris.size(); index++) {
                clipData.addItem(new ClipData.Item(payload.uris.get(index)));
            }
            send.setClipData(clipData);
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        }
        if (payload.uris.size() == 1) send.putExtra(Intent.EXTRA_STREAM, payload.uris.get(0));
        else if (!payload.uris.isEmpty()) send.putParcelableArrayListExtra(Intent.EXTRA_STREAM, payload.uris);
        if (!payload.text.isEmpty()) send.putExtra(Intent.EXTRA_TEXT, payload.text);
        Intent chooser = payload.clearAfterShare
            ? Intent.createChooser(send, "선택 항목 공유", ShareSelectionReceiver.forItems(this, payload.selected))
            : Intent.createChooser(send, "선택 항목 공유");
        try {
            startActivity(chooser);
        } catch (ActivityNotFoundException exception) {
            toast("공유할 앱을 찾을 수 없습니다");
        }
    }

    private static final class PreparedShare {
        final ArrayList<Uri> uris;
        final String sendType;
        final String text;
        final List<StackItem> selected;
        final boolean clearAfterShare;

        PreparedShare(ArrayList<Uri> uris, String sendType, String text, List<StackItem> selected,
                      boolean clearAfterShare) {
            this.uris = uris;
            this.sendType = sendType;
            this.text = text;
            this.selected = selected;
            this.clearAfterShare = clearAfterShare;
        }
    }

    private String commonType(List<StackItem> selected) {
        String type = selected.get(0).mimeType;
        boolean exactMatch = true;
        int slash = type.indexOf('/');
        if (slash <= 0) return "*/*";
        String family = type.substring(0, slash);
        for (StackItem item : selected) {
            if (!type.equals(item.mimeType)) exactMatch = false;
            int itemSlash = item.mimeType.indexOf('/');
            if (itemSlash <= 0 || !family.equals(item.mimeType.substring(0, itemSlash))) return "*/*";
        }
        if (!exactMatch) return family + "/*";
        return type;
    }

    private String selectedText(List<StackItem> selected) {
        StringBuilder text = new StringBuilder();
        for (StackItem item : selected) if ("text/plain".equals(item.mimeType)) {
            try (FileInputStream input = new FileInputStream(itemFile(item.id))) {
                byte[] bytes = readAll(input);
                if (text.length() > 0) text.append("\n\n");
                text.append(new String(bytes, StandardCharsets.UTF_8));
            } catch (IOException ignored) { }
        }
        return text.toString();
    }

    private static byte[] readAll(InputStream input) throws IOException {
        java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
        byte[] buffer = new byte[64 * 1024];
        int count;
        while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
        return output.toByteArray();
    }

    private void clearSelected() {
        List<StackItem> selected = selected(); if (selected.isEmpty()) return;
        for (StackItem item : selected) new File(getFilesDir(), "items/" + item.id).delete(); items.removeAll(selected); saveItems(); render();
    }

    private String copyForSharing(StackItem item) throws IOException {
        String id = UUID.randomUUID().toString();
        File sharedFile = new File(getFilesDir(), "shared/" + id);
        sharedFile.getParentFile().mkdirs();
        try (FileInputStream input = new FileInputStream(itemFile(item.id)); FileOutputStream output = new FileOutputStream(sharedFile)) {
            byte[] buffer = new byte[64 * 1024]; int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            return id;
        } catch (IOException exception) {
            sharedFile.delete();
            throw exception;
        }
    }

    private Uri createZipForSharing(List<StackItem> files) throws IOException {
        String id = UUID.randomUUID().toString() + ".zip";
        File zipFile = new File(getFilesDir(), "shared/" + id);
        zipFile.getParentFile().mkdirs();
        try (ZipOutputStream zip = new ZipOutputStream(new FileOutputStream(zipFile))) {
            byte[] buffer = new byte[64 * 1024];
            for (int index = 0; index < files.size(); index++) {
                StackItem item = files.get(index);
                String safeName = item.name.replace('/', '_').replace('\\', '_').trim();
                if (safeName.isEmpty()) safeName = "file";
                zip.putNextEntry(new ZipEntry(String.format(Locale.US, "%02d_%s", index + 1, safeName)));
                try (FileInputStream input = new FileInputStream(itemFile(item.id))) {
                    int count;
                    while ((count = input.read(buffer)) != -1) zip.write(buffer, 0, count);
                }
                zip.closeEntry();
            }
            return contentUri("shared/", id, "ShareStack-files.zip", "application/zip");
        } catch (IOException exception) {
            zipFile.delete();
            throw exception;
        }
    }

    private Uri contentUri(String directory, String id, String name, String type) {
        return Uri.parse("content://com.pdg.sharestack.items/" + directory + id
            + "?name=" + Uri.encode(name) + "&type=" + Uri.encode(type));
    }

    private void loadItems() {
        cleanupExpiredSharedFiles();
        items.addAll(StackStore.load(this));
        int sortMode = getSharedPreferences(PREFS, MODE_PRIVATE).getInt(SORT_MODE, SORT_MANUAL);
        if (sortMode == SORT_NEWEST) {
            java.util.Collections.sort(items, (first, second) -> Long.compare(second.createdAt, first.createdAt));
        } else if (sortMode == SORT_OLDEST) {
            java.util.Collections.sort(items, (first, second) -> Long.compare(first.createdAt, second.createdAt));
        }
    }

    private void saveItems() {
        StackStore.saveKeepingIncoming(this, items);
    }

    private File itemFile(String id) { return new File(getFilesDir(), "items/" + id); }
    private void cleanupExpiredSharedFiles() {
        File directory = new File(getFilesDir(), "shared"); directory.mkdirs();
        long cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000;
        File[] files = directory.listFiles(); if (files == null) return;
        for (File file : files) if (file.lastModified() < cutoff) file.delete();
    }
    private String contentTypeLabel(String mimeType) {
        if ("text/plain".equals(mimeType)) return "텍스트";
        if (mimeType.startsWith("image/")) return "이미지";
        if (mimeType.startsWith("video/")) return "동영상";
        if (mimeType.startsWith("audio/")) return "오디오";
        if ("application/pdf".equals(mimeType)) return "PDF 문서";
        return "파일";
    }
    private void applyLockIndicator(TextView view, StackItem item) {
        if (!item.locked) return;
        view.setCompoundDrawablesWithIntrinsicBounds(0, 0, R.drawable.ic_lock, 0);
        view.setCompoundDrawablePadding(dp(6));
    }
    private String shorten(String text) { return text.length() > 80 ? text.substring(0, 77) + "…" : text; }
    private void toast(String message) { Toast.makeText(this, message, Toast.LENGTH_SHORT).show(); }
}
