package com.pdg.sharestack;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
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
import android.text.TextUtils;
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
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public final class MainActivity extends Activity {
    private static final String PREFS = "stack";
    private static final String CLEAR_STACK_AFTER_SHARE = "clear_and_close_after_share";
    private static final String VIEW_MODE = "view_mode";
    private static final String GRID_MODE = "grid";
    private static final String LIST_MODE = "list";
    private static final int BADGE_PERMISSION_REQUEST = 1002;
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
    private Button deleteButton;
    private ImageButton viewButton;
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
        selectedItemIds.clear();
        for (CheckBox selection : selections) {
            if (selection.isChecked()) selectedItemIds.add((String) selection.getTag());
        }
        items.clear();
        loadItems();
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
        View toolbarSpacer = new View(this);
        ImageButton settings = new ImageButton(this);
        styleIconButton(settings, R.drawable.ic_settings, "설정");
        settings.setOnClickListener(v -> showSettings());
        viewButton = new ImageButton(this);
        styleIconButton(viewButton, R.drawable.ic_view_list, "목록 보기로 전환");
        viewButton.setOnClickListener(v -> toggleViewMode());
        selectionSummary = new TextView(this);
        selectionSummary.setTextSize(13);
        selectionSummary.setGravity(Gravity.CENTER);
        selectionSummary.setPadding(dp(10), 0, dp(10), 0);
        selectionSummary.setBackground(roundedBackground(0xffe9efff, 0, 50));
        LinearLayout.LayoutParams summaryParams = new LinearLayout.LayoutParams(-2, dp(32));
        summaryParams.setMargins(0, 0, dp(8), 0);
        toolbar.addView(toolbarSpacer, new LinearLayout.LayoutParams(0, dp(48), 1));
        toolbar.addView(selectionSummary, summaryParams);
        toolbar.addView(viewButton, new LinearLayout.LayoutParams(dp(48), dp(48)));
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
        copyButton.setOnClickListener(v -> copySelectedText());
        deleteButton = new Button(this);
        deleteButton.setText("선택 삭제");
        styleActionButton(deleteButton, 0xfffff0f2, DANGER, 0, 14, 12);
        deleteButton.setOnClickListener(v -> clearSelected());
        LinearLayout.LayoutParams shareParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        shareParams.setMargins(0, 0, dp(3), 0);
        LinearLayout.LayoutParams copyParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        copyParams.setMargins(dp(3), 0, dp(3), 0);
        LinearLayout.LayoutParams clearParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        clearParams.setMargins(dp(3), 0, 0, 0);
        actions.addView(shareButton, shareParams);
        actions.addView(copyButton, copyParams);
        actions.addView(deleteButton, clearParams);
        root.addView(actions, actionsParams);
        setContentView(root);
        render();
    }

    private void showSettings() {
        Dialog dialog = new Dialog(this);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(24), dp(24), dp(24), dp(18));
        panel.setBackground(roundedBackground(SURFACE, BORDER, 24));
        TextView title = new TextView(this);
        title.setText("설정");
        title.setTextSize(22);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setTextColor(INK);
        panel.addView(title);
        TextView description = new TextView(this);
        description.setText("공유를 받을 때와 보낸 뒤 동작을 선택하세요.");
        description.setTextSize(14);
        description.setTextColor(MUTED);
        description.setPadding(0, dp(6), 0, dp(18));
        panel.addView(description);
        CheckBox clearAfterShare = new CheckBox(this);
        clearAfterShare.setText("공유 후 스택 비우기");
        clearAfterShare.setChecked(getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(CLEAR_STACK_AFTER_SHARE, false));
        clearAfterShare.setTextSize(15);
        clearAfterShare.setTextColor(INK);
        clearAfterShare.setButtonTintList(new ColorStateList(new int[][] {new int[] {android.R.attr.state_checked}, new int[] {}}, new int[] {PRIMARY, 0xffa2adbd}));
        LinearLayout option = new LinearLayout(this);
        option.setGravity(Gravity.CENTER_VERTICAL);
        option.setPadding(dp(10), dp(7), dp(8), dp(7));
        option.setBackground(roundedBackground(0xfff0f5ff, 0, 16));
        option.addView(clearAfterShare, new LinearLayout.LayoutParams(-1, dp(48)));
        panel.addView(option);
        CheckBox openAfterReceiving = new CheckBox(this);
        openAfterReceiving.setText("공유받은 뒤 앱 열기");
        openAfterReceiving.setChecked(getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(StackStore.OPEN_AFTER_RECEIVING, false));
        openAfterReceiving.setTextSize(15);
        openAfterReceiving.setTextColor(INK);
        openAfterReceiving.setButtonTintList(new ColorStateList(new int[][] {new int[] {android.R.attr.state_checked}, new int[] {}}, new int[] {PRIMARY, 0xffa2adbd}));
        LinearLayout receiveOption = new LinearLayout(this);
        receiveOption.setGravity(Gravity.CENTER_VERTICAL);
        receiveOption.setPadding(dp(10), dp(7), dp(8), dp(7));
        receiveOption.setBackground(roundedBackground(0xfff0f5ff, 0, 16));
        receiveOption.addView(openAfterReceiving, new LinearLayout.LayoutParams(-1, dp(48)));
        LinearLayout.LayoutParams receiveOptionParams = new LinearLayout.LayoutParams(-1, -2);
        receiveOptionParams.setMargins(0, dp(8), 0, 0);
        panel.addView(receiveOption, receiveOptionParams);
        LinearLayout buttons = new LinearLayout(this);
        buttons.setGravity(Gravity.CENTER_VERTICAL);
        buttons.setPadding(0, dp(20), 0, 0);
        Button cancel = new Button(this);
        cancel.setText("취소");
        styleButton(cancel, 0xffeef3ff, PRIMARY_DARK, 0, 14, 14);
        cancel.setOnClickListener(v -> dialog.dismiss());
        Button save = new Button(this);
        save.setText("저장");
        styleButton(save, PRIMARY, Color.WHITE, 0, 14, 14);
        save.setOnClickListener(v -> {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putBoolean(CLEAR_STACK_AFTER_SHARE, clearAfterShare.isChecked())
                .putBoolean(StackStore.OPEN_AFTER_RECEIVING, openAfterReceiving.isChecked())
                .apply();
            dialog.dismiss();
        });
        LinearLayout.LayoutParams cancelParams = new LinearLayout.LayoutParams(0, dp(48), 1);
        cancelParams.setMargins(0, 0, dp(4), 0);
        LinearLayout.LayoutParams saveParams = new LinearLayout.LayoutParams(0, dp(48), 1);
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

    private void toggleViewMode() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putString(VIEW_MODE, isListMode() ? GRID_MODE : LIST_MODE)
            .apply();
        render();
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

        card.addView(previewFor(item), new FrameLayout.LayoutParams(-1, -1));
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
        details.addView(name);
        card.addView(details, new FrameLayout.LayoutParams(-1, dp(44), Gravity.BOTTOM));
        card.setOnClickListener(v -> box.setChecked(!box.isChecked()));

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
        compact.addView(name, new FrameLayout.LayoutParams(-1, -1));
        CheckBox box = newSelectionBox(item);
        compact.addView(box, new FrameLayout.LayoutParams(dp(48), dp(48), Gravity.CENTER_VERTICAL | Gravity.END));
        compact.setOnClickListener(v -> box.setChecked(!box.isChecked()));
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
        previewArea.addView(previewFor(item), new FrameLayout.LayoutParams(-1, -1));
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
        for (CheckBox selection : selections) if (selection.isChecked()) selectedCount++;
        if (viewButton != null) {
            boolean listMode = isListMode();
            viewButton.setImageResource(listMode ? R.drawable.ic_view_grid : R.drawable.ic_view_list);
            viewButton.setContentDescription(listMode ? "카드 보기로 전환" : "목록 보기로 전환");
        }
        if (selectionSummary != null) {
            selectionSummary.setText(selectedCount == 0 ? items.size() + "개" : selectedCount + "개 선택됨");
            selectionSummary.setTextColor(PRIMARY_DARK);
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
            for (StackItem item : items) {
                if (isItemSelected(item) && "text/plain".equals(item.mimeType)) {
                    hasSelectedText = true;
                    break;
                }
            }
            copyButton.setEnabled(hasSelectedText);
            styleActionButton(copyButton, hasSelectedText ? 0xffeef3ff : 0xffeff2f6, hasSelectedText ? PRIMARY_DARK : 0xff66758d, 0, 14, 12);
            copyButton.setAlpha(1f);
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
        boolean clearAfterShare = getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean(CLEAR_STACK_AFTER_SHARE, false);
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
            if (clearAfterShare) clearStack();
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
        startActivity(Intent.createChooser(send, "선택 항목 공유"));
        if (clearAfterShare) {
            clearStack();
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

    private void copySelectedText() {
        String text = selectedText(selected());
        if (text.isEmpty()) { toast("선택한 항목에 텍스트가 없습니다"); return; }
        copyTextToClipboard(text);
        toast("텍스트를 클립보드에 복사했습니다");
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

    private void clearStack() {
        for (StackItem item : items) itemFile(item.id).delete();
        items.clear(); saveItems(); render();
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
    private String shorten(String text) { return text.length() > 80 ? text.substring(0, 77) + "…" : text; }
    private void toast(String message) { Toast.makeText(this, message, Toast.LENGTH_SHORT).show(); }
}
