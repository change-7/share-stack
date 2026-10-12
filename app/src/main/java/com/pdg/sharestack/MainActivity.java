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
import android.content.ClipboardManager;
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
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.provider.MediaStore;
import android.provider.DocumentsContract;
import android.text.TextUtils;
import android.view.DragEvent;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.widget.Button;
import android.widget.CheckBox;
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
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.text.SimpleDateFormat;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public final class MainActivity extends Activity {
    private static final String PREFS = "stack";
    private static final String VIEW_MODE = "view_mode";
    private static final String GRID_MODE = "grid";
    private static final String LIST_MODE = "list";
    private static final int BADGE_PERMISSION_REQUEST = 1002;
    private static final int ARCHIVE_FOLDER_REQUEST = 1004;
    private static final String ARCHIVE_FOLDER_URI = "archive_folder_uri";
    private static final String ARCHIVE_FOLDER_NAME = "archive_folder_name";
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
    private TextView selectionSummary;
    private Button shareButton;
    private Button copyButton;
    private Button archiveButton;
    private Button deleteButton;
    private Button selectionToggleButton;
    private Button archiveFolderSettingButton;
    private ArrayList<String> pendingArchiveItemIds;
    private boolean archivingItems;
    private boolean selectionsInitialized;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        loadItems();
        buildUi();
        requestBadgePermissionIfNeeded();
    }

    @Override public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        reloadItems();
        requestBadgePermissionIfNeeded();
    }

    @Override public void onResume() {
        super.onResume();
        if (list != null) reloadItems();
    }

    private void reloadItems() {
        ArrayList<String> existingItemIds = new ArrayList<>();
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
        ImageButton camera = new ImageButton(this);
        styleIconButton(camera, R.drawable.ic_camera, "카메라로 추가");
        camera.setOnClickListener(v -> startCapture());
        View toolbarSpacer = new View(this);
        ImageButton settings = new ImageButton(this);
        styleIconButton(settings, R.drawable.ic_settings, "설정");
        settings.setOnClickListener(v -> showSettings());
        selectionSummary = new TextView(this);
        selectionSummary.setTextSize(13);
        selectionSummary.setGravity(Gravity.CENTER);
        selectionSummary.setPadding(dp(10), 0, dp(10), 0);
        selectionSummary.setBackground(roundedBackground(0xffe9efff, 0, 50));
        LinearLayout.LayoutParams summaryParams = new LinearLayout.LayoutParams(-2, dp(32));
        summaryParams.setMargins(0, 0, dp(6), 0);
        selectionToggleButton = new Button(this);
        styleActionButton(selectionToggleButton, 0xffeef3ff, PRIMARY_DARK, 0, 14, 12);
        selectionToggleButton.setOnClickListener(v -> toggleAllItems());
        LinearLayout.LayoutParams selectionToggleParams = new LinearLayout.LayoutParams(dp(112), dp(40));
        selectionToggleParams.setMargins(0, 0, dp(6), 0);
        toolbar.addView(camera, new LinearLayout.LayoutParams(dp(48), dp(48)));
        toolbar.addView(toolbarSpacer, new LinearLayout.LayoutParams(0, dp(48), 1));
        toolbar.addView(selectionSummary, summaryParams);
        toolbar.addView(selectionToggleButton, selectionToggleParams);
        toolbar.addView(settings, new LinearLayout.LayoutParams(dp(48), dp(48)));
        LinearLayout.LayoutParams toolbarParams = new LinearLayout.LayoutParams(-1, dp(48));
        toolbarParams.setMargins(0, 0, 0, dp(12));
        root.addView(toolbar, toolbarParams);

        ScrollView scroll = new ScrollView(this);
        scroll.setClipToPadding(false);
        scroll.setFillViewport(true);
        scroll.setVerticalScrollBarEnabled(false);
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        scroll.addView(list);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams actionsParams = new LinearLayout.LayoutParams(-1, -2);
        actionsParams.setMargins(0, dp(12), 0, 0);
        shareButton = new Button(this);
        styleActionButton(shareButton, PRIMARY, Color.WHITE, 0, 14, 12);
        shareButton.setOnClickListener(v -> shareSelected());
        copyButton = new Button(this);
        copyButton.setText("텍스트 복사");
        styleActionButton(copyButton, 0xffeef3ff, PRIMARY_DARK, 0, 14, 12);
        copyButton.setOnClickListener(v -> copySelectedContent());
        archiveButton = new Button(this);
        archiveButton.setText("보관");
        styleActionButton(archiveButton, 0xffeef3ff, PRIMARY_DARK, 0, 14, 12);
        archiveButton.setContentDescription("선택 항목을 보관 폴더에 저장");
        archiveButton.setOnClickListener(v -> saveSelectedToFolder());
        deleteButton = new Button(this);
        deleteButton.setText("선택 삭제");
        styleActionButton(deleteButton, 0xfffff0f2, DANGER, 0, 14, 12);
        deleteButton.setOnClickListener(v -> clearSelected());
        LinearLayout.LayoutParams shareParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        shareParams.setMargins(0, 0, dp(2), 0);
        LinearLayout.LayoutParams copyParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        copyParams.setMargins(dp(2), 0, dp(2), 0);
        LinearLayout.LayoutParams archiveParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        archiveParams.setMargins(dp(2), 0, dp(2), 0);
        LinearLayout.LayoutParams clearParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        clearParams.setMargins(dp(2), 0, 0, 0);
        actions.addView(shareButton, shareParams);
        actions.addView(copyButton, copyParams);
        actions.addView(archiveButton, archiveParams);
        actions.addView(deleteButton, clearParams);
        root.addView(actions, actionsParams);
        setContentView(root);
        render();
    }

    private void startCapture() {
        Intent capture = new Intent(this, CaptureActivity.class)
            .putExtra(CaptureActivity.EXTRA_CAPTURE_ID, java.util.UUID.randomUUID() + ".jpg");
        startActivity(capture);
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
        addSettingsDivider(panel);
        archiveFolderSettingButton = new Button(this);
        stylePlainSettingsButton(archiveFolderSettingButton);
        updateArchiveFolderButton(archiveFolderSettingButton);
        archiveFolderSettingButton.setOnClickListener(view -> chooseArchiveFolder(null));
        panel.addView(archiveFolderSettingButton,
            new LinearLayout.LayoutParams(-1, dp(44)));
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

    private void updateArchiveFolderButton(Button button) {
        String folderName = getSharedPreferences(PREFS, MODE_PRIVATE)
            .getString(ARCHIVE_FOLDER_NAME, null);
        button.setText(folderName == null || folderName.isEmpty()
            ? "보관 폴더 지정" : "보관 폴더 · " + folderName);
        button.setSingleLine(true);
        button.setEllipsize(TextUtils.TruncateAt.END);
    }

    private void saveSelectedToFolder() {
        List<StackItem> chosen = selected();
        if (chosen.isEmpty()) {
            toast("보관할 항목을 선택하세요");
            return;
        }
        String savedUri = getSharedPreferences(PREFS, MODE_PRIVATE)
            .getString(ARCHIVE_FOLDER_URI, null);
        if (savedUri == null || savedUri.isEmpty()) {
            ArrayList<String> itemIds = new ArrayList<>();
            for (StackItem item : chosen) itemIds.add(item.id);
            chooseArchiveFolder(itemIds);
            return;
        }
        archiveItems(chosen, Uri.parse(savedUri));
    }

    private void chooseArchiveFolder(ArrayList<String> itemIds) {
        pendingArchiveItemIds = itemIds == null ? null : new ArrayList<>(itemIds);
        Intent picker = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        try {
            startActivityForResult(picker, ARCHIVE_FOLDER_REQUEST);
        } catch (ActivityNotFoundException | SecurityException exception) {
            pendingArchiveItemIds = null;
            toast("폴더 선택 화면을 열 수 없습니다");
        }
    }

    private String archiveFolderName(Uri treeUri) {
        String documentId = DocumentsContract.getTreeDocumentId(treeUri);
        if (documentId == null || documentId.isEmpty()) return "선택됨";
        int separator = Math.max(documentId.lastIndexOf('/'), documentId.lastIndexOf(':'));
        String name = documentId.substring(separator + 1).trim();
        return name.isEmpty() ? "선택됨" : name;
    }

    private void archiveItems(List<StackItem> selectedItems, Uri treeUri) {
        if (archivingItems || selectedItems.isEmpty()) return;
        archivingItems = true;
        updateSelectionState();
        toast("선택한 항목을 폴더에 보관합니다");
        ArrayList<StackItem> snapshot = new ArrayList<>(selectedItems);
        new Thread(() -> {
            Set<String> existingNames = existingArchiveNames(treeUri);
            int saved = 0;
            int failed = 0;
            for (StackItem item : snapshot) {
                Uri createdDocument = null;
                try {
                    String fileName = uniqueArchiveName(archiveFileName(item), existingNames);
                    String mimeType = item.mimeType == null || item.mimeType.isEmpty()
                        ? "application/octet-stream" : item.mimeType;
                    createdDocument = DocumentsContract.createDocument(
                        getContentResolver(), treeUri, mimeType, fileName);
                    if (createdDocument == null) throw new IOException("Document provider returned no URI");
                    try (InputStream input = new FileInputStream(itemFile(item.id));
                         OutputStream output = getContentResolver().openOutputStream(createdDocument, "w")) {
                        if (output == null) throw new IOException("Document provider returned no output stream");
                        byte[] buffer = new byte[8192];
                        int count;
                        while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                    }
                    saved++;
                } catch (Exception exception) {
                    if (createdDocument != null) {
                        try {
                            DocumentsContract.deleteDocument(getContentResolver(), createdDocument);
                        } catch (Exception ignored) { }
                    }
                    failed++;
                }
            }
            int savedCount = saved;
            int failedCount = failed;
            runOnUiThread(() -> {
                archivingItems = false;
                updateSelectionState();
                toast(savedCount + "개 보관 완료" + (failedCount == 0 ? "" : ", " + failedCount + "개 실패"));
            });
        }, "share-stack-folder-archive").start();
    }

    private Set<String> existingArchiveNames(Uri treeUri) {
        HashSet<String> names = new HashSet<>();
        try {
            Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri, DocumentsContract.getTreeDocumentId(treeUri));
            try (Cursor cursor = getContentResolver().query(childrenUri,
                new String[] {DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
                if (cursor != null) {
                    int nameColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME);
                    while (nameColumn >= 0 && cursor.moveToNext()) {
                        String name = cursor.getString(nameColumn);
                        if (name != null) names.add(name.toLowerCase(Locale.ROOT));
                    }
                }
            }
        } catch (Exception ignored) {
            // ponytail: some document providers cannot list children; use provider create semantics for collisions.
        }
        return names;
    }

    private String archiveFileName(StackItem item) {
        String name;
        if ("text/plain".equals(item.mimeType)) {
            String timestamp = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
                .format(new Date(item.createdAt));
            name = "텍스트_" + timestamp + ".txt";
        } else {
            name = item.name == null ? "파일" : item.name;
        }
        name = name.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_").trim();
        while (name.endsWith(".")) name = name.substring(0, name.length() - 1).trim();
        return name.isEmpty() ? "파일" : name;
    }

    private String uniqueArchiveName(String originalName, Set<String> existingNames) {
        int extensionIndex = originalName.lastIndexOf('.');
        if (extensionIndex <= 0) extensionIndex = originalName.length();
        String base = originalName.substring(0, extensionIndex);
        String extension = originalName.substring(extensionIndex);
        String candidate = originalName;
        int suffix = 1;
        while (existingNames.contains(candidate.toLowerCase(Locale.ROOT))) {
            candidate = base + " (" + suffix++ + ")" + extension;
        }
        existingNames.add(candidate.toLowerCase(Locale.ROOT));
        return candidate;
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
    }

    private void addItemCard(LinearLayout row, StackItem item, boolean firstInRow) {
        FrameLayout card = new FrameLayout(this);
        card.setBackground(roundedBackground(SURFACE, BORDER, 18));
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
        details.setBackgroundColor(0xa0ffffff);
        TextView name = new TextView(this);
        name.setText(item.name);
        name.setTextSize(14);
        name.setTextColor(INK);
        name.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        name.setMaxLines(1);
        name.setSingleLine(true);
        name.setEllipsize(TextUtils.TruncateAt.END);
        applyLockIndicator(name, item);
        details.addView(name);
        card.addView(details, new FrameLayout.LayoutParams(-1, dp(44), Gravity.BOTTOM));
        card.setOnClickListener(v -> box.setChecked(!box.isChecked()));
        enableReorder(card, item);

        LinearLayout.LayoutParams cardParams = new LinearLayout.LayoutParams(0, -1, 1);
        cardParams.setMargins(firstInRow ? 0 : dp(5), 0, firstInRow ? dp(5) : 0, 0);
        row.addView(card, cardParams);
    }

    private void addCompactGridItem(StackItem item) {
        FrameLayout compact = new FrameLayout(this);
        compact.setBackground(roundedBackground(SURFACE, BORDER, 14));
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
        compact.addView(name, new FrameLayout.LayoutParams(-1, -1));
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
        card.setBackground(roundedBackground(SURFACE, BORDER, 18));
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
        content.addView(previewArea, new LinearLayout.LayoutParams(dp(108), dp(76)));

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
        details.addView(name);
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
            byte[] bytes = new byte[input.available()];
            int length = input.read(bytes);
            return length > 0 ? new String(bytes, 0, length, StandardCharsets.UTF_8) : "";
        } catch (IOException ignored) {
            return "텍스트를 불러올 수 없습니다";
        }
    }

    private View detailPreviewFor(StackItem item) {
        Bitmap bitmap = null;
        if (item.mimeType.startsWith("image/")) bitmap = imageThumbnail(itemFile(item.id));
        else if (item.mimeType.startsWith("video/")) bitmap = videoThumbnail(itemFile(item.id));
        else if ("application/pdf".equals(item.mimeType)) bitmap = pdfThumbnail(itemFile(item.id));
        if (bitmap == null) return previewTile(item);
        ImageView image = new ImageView(this);
        image.setImageBitmap(bitmap);
        image.setScaleType(ImageView.ScaleType.FIT_CENTER);
        image.setBackgroundColor(0xfff1f3f4);
        return image;
    }

    private boolean isThumbnailCapable(StackItem item) {
        return item.mimeType.startsWith("image/") || item.mimeType.startsWith("video/") || "application/pdf".equals(item.mimeType);
    }

    private View previewFor(StackItem item) {
        Bitmap thumbnail = null;
        if (item.mimeType.startsWith("image/")) thumbnail = imageThumbnail(itemFile(item.id));
        else if (item.mimeType.startsWith("video/")) thumbnail = videoThumbnail(itemFile(item.id));
        else if ("application/pdf".equals(item.mimeType)) thumbnail = pdfThumbnail(itemFile(item.id));
        if (thumbnail == null) return previewTile(item);

        FrameLayout frame = new FrameLayout(this);
        ImageView image = new ImageView(this);
        image.setImageBitmap(thumbnail);
        image.setScaleType(ImageView.ScaleType.CENTER_CROP);
        image.setBackground(roundedBackground(0xfff1f3f4, 0));
        frame.addView(image, new FrameLayout.LayoutParams(-1, -1));
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
            byte[] bytes = new byte[Math.min(input.available(), 240)];
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
        if (selectionSummary != null) {
            selectionSummary.setText(selectedCount == 0 ? items.size() + "개" : selectedCount + "개 선택됨");
            selectionSummary.setTextColor(PRIMARY_DARK);
        }
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
        if (copyButton != null) {
            boolean hasSelectedText = false;
            boolean hasSelectedFile = false;
            for (StackItem item : items) {
                if (isItemSelected(item)) {
                    if (!"text/plain".equals(item.mimeType)) hasSelectedFile = true;
                    if ("text/plain".equals(item.mimeType)) hasSelectedText = true;
                }
            }
            boolean canCopy = hasSelectedFile || hasSelectedText;
            copyButton.setEnabled(canCopy);
            copyButton.setText(hasSelectedFile ? "파일 복사" : "텍스트 복사");
            styleActionButton(copyButton, canCopy ? 0xffeef3ff : 0xffeff2f6, canCopy ? PRIMARY_DARK : 0xff66758d, 0, 14, 12);
            copyButton.setAlpha(1f);
        }
        if (archiveButton != null) {
            boolean canArchive = selectedCount > 0 && !archivingItems;
            archiveButton.setEnabled(canArchive);
            archiveButton.setText(archivingItems ? "저장 중" : "보관");
            styleActionButton(archiveButton, canArchive ? 0xffeef3ff : 0xffeff2f6,
                canArchive ? PRIMARY_DARK : 0xff66758d, 0, 14, 12);
            archiveButton.setContentDescription("선택 항목을 보관 폴더에 저장");
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

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != ARCHIVE_FOLDER_REQUEST) return;
        ArrayList<String> itemIdsToArchive = pendingArchiveItemIds;
        pendingArchiveItemIds = null;
        if (resultCode != RESULT_OK || data == null || data.getData() == null) return;

        Uri treeUri = data.getData();
        int grantFlags = data.getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION
            | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        if ((grantFlags & Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == 0) {
            toast("선택한 폴더에 쓸 권한이 없습니다");
            return;
        }
        try {
            getContentResolver().takePersistableUriPermission(treeUri, grantFlags);
        } catch (SecurityException exception) {
            toast("폴더 접근 권한을 저장할 수 없습니다");
            return;
        }

        String folderName = archiveFolderName(treeUri);
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putString(ARCHIVE_FOLDER_URI, treeUri.toString())
            .putString(ARCHIVE_FOLDER_NAME, folderName)
            .apply();
        if (archiveFolderSettingButton != null) {
            updateArchiveFolderButton(archiveFolderSettingButton);
        }
        if (itemIdsToArchive != null && !itemIdsToArchive.isEmpty()) {
            ArrayList<StackItem> chosen = new ArrayList<>();
            for (StackItem item : items) {
                if (itemIdsToArchive.contains(item.id)) chosen.add(item);
            }
            if (chosen.isEmpty()) toast("보관할 스택 항목을 찾을 수 없습니다");
            else archiveItems(chosen, treeUri);
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

    private void shareSelected() {
        List<StackItem> selected = selected();
        if (selected.isEmpty()) { toast("공유할 항목을 선택하세요"); return; }
        int fileCount = 0;
        for (StackItem item : selected) if (!"text/plain".equals(item.mimeType)) fileCount++;
        if (fileCount > 1) {
            boolean hasText = !selectedText(selected).isEmpty();
            new AlertDialog.Builder(this)
                .setTitle("공유 방식")
                .setMessage(hasText
                    ? "파일은 공유 화면으로 보내고 텍스트는 클립보드에 복사합니다. 대상 앱이 여러 파일을 받지 못하면 ZIP으로 공유하세요."
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
        boolean clearAfterShare = getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(StackStore.CLEAR_STACK_AFTER_SHARE, false);
        ArrayList<Uri> uris = new ArrayList<>();
        ArrayList<StackItem> sharedFiles = new ArrayList<>();
        String text = selectedText(selected);
        for (StackItem item : selected) if (!"text/plain".equals(item.mimeType)) {
            sharedFiles.add(item);
        }
        if (sharedFiles.isEmpty()) {
            if (text.isEmpty()) { toast("공유할 내용을 찾을 수 없습니다"); return; }
            copyTextToClipboard(text);
            toast("텍스트를 클립보드에 복사했습니다");
            if (clearAfterShare) clearUnlockedStack();
            return;
        }
        String sendType;
        if (zipFiles && sharedFiles.size() > 1) {
            Uri zipUri = createZipForSharing(sharedFiles);
            if (zipUri == null) return;
            uris.add(zipUri);
            sendType = "application/zip";
        } else {
            for (StackItem item : sharedFiles) {
                String id = clearAfterShare ? copyForSharing(item) : item.id;
                if (id == null) return;
                uris.add(contentUri(clearAfterShare ? "shared/" : "", id, item.name, item.mimeType));
            }
            sendType = uris.isEmpty() ? "text/plain" : commonType(sharedFiles);
        }
        Intent send = new Intent(uris.size() <= 1 ? Intent.ACTION_SEND : Intent.ACTION_SEND_MULTIPLE);
        send.setType(sendType);
        if (!uris.isEmpty()) {
            ClipData clipData = ClipData.newRawUri("Share Stack items", uris.get(0));
            for (int index = 1; index < uris.size(); index++) clipData.addItem(new ClipData.Item(uris.get(index)));
            send.setClipData(clipData);
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        }
        if (uris.size() == 1) send.putExtra(Intent.EXTRA_STREAM, uris.get(0));
        else if (uris.size() > 1) send.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
        if (!text.isEmpty()) {
            copyTextToClipboard(text);
            toast("텍스트를 복사했습니다. 대상 앱에서 붙여넣으세요.");
        }
        Intent chooser = clearAfterShare
            ? Intent.createChooser(send, "선택 항목 공유", ShareSelectionReceiver.forItems(this, selected))
            : Intent.createChooser(send, "선택 항목 공유");
        startActivity(chooser);
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

    private void copySelectedContent() {
        List<StackItem> selected = selected();
        ArrayList<StackItem> files = new ArrayList<>();
        for (StackItem item : selected) if (!"text/plain".equals(item.mimeType)) files.add(item);
        if (!files.isEmpty()) {
            copyFilesToClipboard(files);
            return;
        }
        String text = selectedText(selected);
        if (text.isEmpty()) { toast("선택한 항목에 텍스트가 없습니다"); return; }
        copyTextToClipboard(text);
        toast("텍스트를 클립보드에 복사했습니다");
    }

    private void copyFilesToClipboard(List<StackItem> files) {
        StackItem first = files.get(0);
        Uri firstUri = contentUri("", first.id, first.name, first.mimeType);
        ClipData clip = new ClipData("Share Stack files",
            new String[]{commonType(files)}, new ClipData.Item(firstUri));
        for (int index = 1; index < files.size(); index++) {
            StackItem file = files.get(index);
            clip.addItem(getContentResolver(), new ClipData.Item(
                contentUri("", file.id, file.name, file.mimeType)));
        }
        ((ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE)).setPrimaryClip(clip);
        toast(files.size() + "개의 파일을 클립보드에 복사했습니다");
    }

    private void copyTextToClipboard(String text) {
        ((ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE))
            .setPrimaryClip(ClipData.newPlainText("Share Stack", text));
    }

    private String selectedText(List<StackItem> selected) {
        StringBuilder text = new StringBuilder();
        for (StackItem item : selected) if ("text/plain".equals(item.mimeType)) {
            try (FileInputStream input = new FileInputStream(itemFile(item.id))) {
                byte[] bytes = new byte[input.available()]; input.read(bytes);
                if (text.length() > 0) text.append("\n\n");
                text.append(new String(bytes, StandardCharsets.UTF_8));
            } catch (IOException ignored) { }
        }
        return text.toString();
    }

    private void clearSelected() {
        List<StackItem> selected = selected(); if (selected.isEmpty()) return;
        for (StackItem item : selected) new File(getFilesDir(), "items/" + item.id).delete(); items.removeAll(selected); saveItems(); render();
    }

    private void clearUnlockedStack() {
        StackStore.removeUnlocked(this);
        items.clear();
        loadItems();
        render();
    }

    private String copyForSharing(StackItem item) {
        String id = UUID.randomUUID().toString();
        File sharedFile = new File(getFilesDir(), "shared/" + id);
        sharedFile.getParentFile().mkdirs();
        try (FileInputStream input = new FileInputStream(itemFile(item.id)); FileOutputStream output = new FileOutputStream(sharedFile)) {
            byte[] buffer = new byte[8192]; int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            return id;
        } catch (IOException exception) {
            sharedFile.delete();
            toast("공유 파일을 준비할 수 없습니다");
            return null;
        }
    }

    private Uri createZipForSharing(List<StackItem> files) {
        String id = UUID.randomUUID().toString() + ".zip";
        File zipFile = new File(getFilesDir(), "shared/" + id);
        zipFile.getParentFile().mkdirs();
        try (ZipOutputStream zip = new ZipOutputStream(new FileOutputStream(zipFile))) {
            byte[] buffer = new byte[8192];
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
            toast("ZIP 파일을 만들 수 없습니다");
            return null;
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
        StackStore.save(this, items);
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
