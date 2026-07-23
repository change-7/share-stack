package com.pdg.sharestack;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.LayerDrawable;
import android.graphics.drawable.RippleDrawable;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Bundle;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.activity.ComponentActivity;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.FocusMeteringAction;
import androidx.camera.core.ImageCapture;
import androidx.camera.core.ImageCaptureException;
import androidx.camera.core.MeteringPoint;
import androidx.camera.core.MeteringPointFactory;
import androidx.camera.core.Preview;
import androidx.camera.core.ZoomState;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.video.FileOutputOptions;
import androidx.camera.video.PendingRecording;
import androidx.camera.video.Quality;
import androidx.camera.video.QualitySelector;
import androidx.camera.video.Recorder;
import androidx.camera.video.Recording;
import androidx.camera.video.VideoCapture;
import androidx.camera.video.VideoRecordEvent;
import androidx.camera.view.PreviewView;

import com.google.common.util.concurrent.ListenableFuture;

import java.io.File;
import java.util.concurrent.ExecutionException;

public final class CaptureActivity extends ComponentActivity {
    static final String EXTRA_CAPTURE_ID = "capture_id";
    static final String EXTRA_CAPTURE_NAME = "capture_name";
    static final String EXTRA_CAPTURE_TYPE = "capture_type";
    private static final int CAMERA_PERMISSION_REQUEST = 2001;
    private static final int AUDIO_PERMISSION_REQUEST = 2002;

    private ImageCapture imageCapture;
    private Recorder recorder;
    private VideoCapture<Recorder> videoCapture;
    private Recording recording;
    private ProcessCameraProvider cameraProvider;
    private Camera camera;
    private PreviewView preview;
    private Button shutter;
    private ImageButton flashButton;
    private View captureFlash;
    private FrameLayout latestCapture;
    private ImageView latestCaptureImage;
    private TextView photoMode;
    private TextView videoMode;
    private String captureBaseId;
    private CameraSelector cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA;
    private int flashMode = ImageCapture.FLASH_MODE_AUTO;
    private boolean videoModeSelected;
    private float zoomRatio = 1f;
    private float minZoomRatio = 1f;
    private float maxZoomRatio = 1f;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(Color.BLACK);
        getWindow().setNavigationBarColor(Color.BLACK);
        getWindow().getDecorView().setSystemUiVisibility(0);
        String captureId = getIntent().getStringExtra(EXTRA_CAPTURE_ID);
        if (captureId == null) {
            setResult(RESULT_CANCELED);
            finish();
            return;
        }
        captureBaseId = captureId.replaceFirst("\\.[^.]+$", "");
        buildUi();
        if (hasCameraPermission()) startCamera();
        else requestPermissions(new String[] {Manifest.permission.CAMERA}, CAMERA_PERMISSION_REQUEST);
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == CAMERA_PERMISSION_REQUEST) {
            if (hasCameraPermission()) startCamera();
            else cancelForMissingCameraPermission();
        } else if (requestCode == AUDIO_PERMISSION_REQUEST) {
            startRecording(hasAudioPermission());
        }
    }

    private boolean hasCameraPermission() {
        return checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean hasAudioPermission() {
        return checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
    }

    private void cancelForMissingCameraPermission() {
        Toast.makeText(this, "카메라 권한이 필요합니다", Toast.LENGTH_SHORT).show();
        setResult(RESULT_CANCELED);
        finish();
    }

    private void buildUi() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        preview = new PreviewView(this);
        preview.setImplementationMode(PreviewView.ImplementationMode.COMPATIBLE);
        root.addView(preview, new FrameLayout.LayoutParams(-1, -1));
        captureFlash = new View(this);
        captureFlash.setBackgroundColor(Color.WHITE);
        captureFlash.setAlpha(0f);
        root.addView(captureFlash, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout topControls = new LinearLayout(this);
        topControls.setGravity(Gravity.CENTER_VERTICAL);
        topControls.setPadding(dp(16), dp(12), dp(16), dp(12));
        topControls.setBackgroundColor(0x55000000);
        ImageButton close = iconButton(R.drawable.ic_close, "카메라 닫기");
        close.setOnClickListener(view -> finish());
        flashButton = iconButton(R.drawable.ic_flash_auto, "플래시 자동");
        flashButton.setOnClickListener(view -> cycleFlash());
        ImageButton switchCamera = iconButton(R.drawable.ic_flip_camera, "전면 카메라로 전환");
        switchCamera.setOnClickListener(view -> switchCamera());
        View spacer = new View(this);
        topControls.addView(close, new LinearLayout.LayoutParams(dp(48), dp(48)));
        topControls.addView(spacer, new LinearLayout.LayoutParams(0, dp(48), 1));
        topControls.addView(flashButton, new LinearLayout.LayoutParams(dp(48), dp(48)));
        topControls.addView(switchCamera, new LinearLayout.LayoutParams(dp(48), dp(48)));
        root.addView(topControls, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP));

        LinearLayout bottomControls = new LinearLayout(this);
        bottomControls.setOrientation(LinearLayout.VERTICAL);
        bottomControls.setGravity(Gravity.CENTER_HORIZONTAL);
        bottomControls.setPadding(dp(16), dp(12), dp(16), dp(20));
        bottomControls.setBackgroundColor(0xb3000000);
        LinearLayout modes = new LinearLayout(this);
        modes.setGravity(Gravity.CENTER);
        photoMode = modeButton("사진", true);
        videoMode = modeButton("동영상", false);
        photoMode.setOnClickListener(view -> selectMode(false));
        videoMode.setOnClickListener(view -> selectMode(true));
        modes.addView(photoMode, new LinearLayout.LayoutParams(dp(72), dp(38)));
        modes.addView(videoMode, new LinearLayout.LayoutParams(dp(72), dp(38)));
        bottomControls.addView(modes, new LinearLayout.LayoutParams(-1, -2));
        shutter = new Button(this);
        shutter.setContentDescription("사진 촬영");
        shutter.setBackground(shutterBackground(false));
        shutter.setPadding(0, 0, 0, 0);
        LinearLayout.LayoutParams shutterParams = new LinearLayout.LayoutParams(dp(82), dp(82));
        shutterParams.topMargin = dp(8);
        bottomControls.addView(shutter, shutterParams);
        root.addView(bottomControls, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        latestCapture = new FrameLayout(this);
        latestCapture.setVisibility(View.INVISIBLE);
        latestCapture.setAlpha(0f);
        latestCapture.setScaleX(0.76f);
        latestCapture.setScaleY(0.76f);
        latestCapture.setBackground(roundBackground(0xdd000000, 14));
        latestCapture.setPadding(dp(2), dp(2), dp(2), dp(2));
        latestCapture.setClipToOutline(true);
        latestCaptureImage = new ImageView(this);
        latestCaptureImage.setScaleType(ImageView.ScaleType.CENTER_CROP);
        latestCaptureImage.setClipToOutline(true);
        latestCaptureImage.setBackground(roundBackground(Color.BLACK, 12));
        latestCapture.addView(latestCaptureImage, new FrameLayout.LayoutParams(-1, -1));
        FrameLayout.LayoutParams latestParams = new FrameLayout.LayoutParams(dp(62), dp(62),
            Gravity.BOTTOM | Gravity.START);
        latestParams.leftMargin = dp(20);
        latestParams.bottomMargin = dp(140);
        root.addView(latestCapture, latestParams);
        shutter.setOnClickListener(view -> capture());
        setContentView(root);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            topControls.setPadding(dp(16), insets.getSystemWindowInsetTop() + dp(12), dp(16), dp(12));
            bottomControls.setPadding(dp(16), dp(12), dp(16), insets.getSystemWindowInsetBottom() + dp(20));
            return insets;
        });

        ScaleGestureDetector scaleDetector = new ScaleGestureDetector(this, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScale(ScaleGestureDetector detector) {
                setZoom(zoomRatio * detector.getScaleFactor());
                return true;
            }
        });
        GestureDetector tapDetector = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onSingleTapUp(MotionEvent event) {
                focusAt(event.getX(), event.getY());
                return true;
            }
        });
        preview.setOnTouchListener((view, event) -> {
            scaleDetector.onTouchEvent(event);
            tapDetector.onTouchEvent(event);
            return true;
        });
    }

    private ImageButton iconButton(int icon, String description) {
        ImageButton button = new ImageButton(this);
        button.setImageResource(icon);
        button.setContentDescription(description);
        button.setPadding(dp(12), dp(12), dp(12), dp(12));
        button.setBackground(roundBackground(0x33000000, 24));
        return button;
    }

    private TextView modeButton(String label, boolean selected) {
        TextView button = new TextView(this);
        button.setText(label);
        button.setTextSize(14);
        button.setGravity(Gravity.CENTER);
        button.setPadding(dp(4), 0, dp(4), 0);
        styleModeButton(button, selected);
        return button;
    }

    private void selectMode(boolean videoMode) {
        if (recording != null || videoModeSelected == videoMode) return;
        videoModeSelected = videoMode;
        styleModeButton(photoMode, !videoMode);
        styleModeButton(this.videoMode, videoMode);
        shutter.setContentDescription(videoMode ? "동영상 녹화 시작" : "사진 촬영");
        shutter.setBackground(shutterBackground(videoMode));
    }

    private void styleModeButton(TextView button, boolean selected) {
        button.setTextColor(selected ? Color.WHITE : 0xffaeb5c1);
        button.setTypeface(android.graphics.Typeface.DEFAULT, selected ? android.graphics.Typeface.BOLD : android.graphics.Typeface.NORMAL);
    }

    private void startCamera() {
        ListenableFuture<ProcessCameraProvider> providerFuture = ProcessCameraProvider.getInstance(this);
        providerFuture.addListener(() -> bindCamera(providerFuture), getMainExecutor());
    }

    private void bindCamera(ListenableFuture<ProcessCameraProvider> providerFuture) {
        try {
            cameraProvider = providerFuture.get();
            Preview cameraPreview = new Preview.Builder().build();
            cameraPreview.setSurfaceProvider(preview.getSurfaceProvider());
            imageCapture = new ImageCapture.Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                .setFlashMode(flashMode)
                .build();
            recorder = new Recorder.Builder()
                .setQualitySelector(QualitySelector.from(Quality.HD))
                .build();
            videoCapture = VideoCapture.withOutput(recorder);
            cameraProvider.unbindAll();
            camera = cameraProvider.bindToLifecycle(this, cameraSelector, cameraPreview, imageCapture, videoCapture);
            ZoomState zoomState = camera.getCameraInfo().getZoomState().getValue();
            if (zoomState != null) {
                minZoomRatio = zoomState.getMinZoomRatio();
                maxZoomRatio = zoomState.getMaxZoomRatio();
                zoomRatio = zoomState.getZoomRatio();
            }
            updateFlashButton();
        } catch (ExecutionException | InterruptedException | IllegalArgumentException exception) {
            if (exception instanceof InterruptedException) Thread.currentThread().interrupt();
            Toast.makeText(this, "카메라를 시작할 수 없습니다", Toast.LENGTH_SHORT).show();
            setResult(RESULT_CANCELED);
            finish();
        }
    }

    private void switchCamera() {
        if (cameraProvider == null || recording != null) return;
        CameraSelector next = cameraSelector == CameraSelector.DEFAULT_BACK_CAMERA
            ? CameraSelector.DEFAULT_FRONT_CAMERA : CameraSelector.DEFAULT_BACK_CAMERA;
        cameraSelector = next;
        bindCameraNow();
    }

    private void bindCameraNow() {
        try {
            if (cameraProvider == null) return;
            Preview cameraPreview = new Preview.Builder().build();
            cameraPreview.setSurfaceProvider(preview.getSurfaceProvider());
            imageCapture = new ImageCapture.Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                .setFlashMode(flashMode)
                .build();
            recorder = new Recorder.Builder().setQualitySelector(QualitySelector.from(Quality.HD)).build();
            videoCapture = VideoCapture.withOutput(recorder);
            cameraProvider.unbindAll();
            camera = cameraProvider.bindToLifecycle(this, cameraSelector, cameraPreview, imageCapture, videoCapture);
            ZoomState zoomState = camera.getCameraInfo().getZoomState().getValue();
            if (zoomState != null) {
                minZoomRatio = zoomState.getMinZoomRatio();
                maxZoomRatio = zoomState.getMaxZoomRatio();
                zoomRatio = zoomState.getZoomRatio();
            }
            updateFlashButton();
        } catch (IllegalArgumentException exception) {
            Toast.makeText(this, "카메라를 전환할 수 없습니다", Toast.LENGTH_SHORT).show();
        }
    }

    private void cycleFlash() {
        if (flashMode == ImageCapture.FLASH_MODE_AUTO) flashMode = ImageCapture.FLASH_MODE_ON;
        else if (flashMode == ImageCapture.FLASH_MODE_ON) flashMode = ImageCapture.FLASH_MODE_OFF;
        else flashMode = ImageCapture.FLASH_MODE_AUTO;
        if (imageCapture != null) imageCapture.setFlashMode(flashMode);
        updateFlashButton();
    }

    private void updateFlashButton() {
        if (flashButton == null) return;
        if (flashMode == ImageCapture.FLASH_MODE_ON) {
            flashButton.setImageResource(R.drawable.ic_flash_on);
            flashButton.setContentDescription("플래시 켜짐");
        } else if (flashMode == ImageCapture.FLASH_MODE_OFF) {
            flashButton.setImageResource(R.drawable.ic_flash_off);
            flashButton.setContentDescription("플래시 꺼짐");
        } else {
            flashButton.setImageResource(R.drawable.ic_flash_auto);
            flashButton.setContentDescription("플래시 자동");
        }
    }

    private void setZoom(float requestedRatio) {
        if (camera == null) return;
        zoomRatio = Math.max(minZoomRatio, Math.min(maxZoomRatio, requestedRatio));
        camera.getCameraControl().setZoomRatio(zoomRatio);
    }

    private void focusAt(float x, float y) {
        if (camera == null) return;
        MeteringPointFactory factory = preview.getMeteringPointFactory();
        MeteringPoint point = factory.createPoint(x, y);
        FocusMeteringAction action = new FocusMeteringAction.Builder(point,
            FocusMeteringAction.FLAG_AF | FocusMeteringAction.FLAG_AE).build();
        camera.getCameraControl().startFocusAndMetering(action);
    }

    private void capture() {
        if (videoModeSelected) toggleRecording();
        else capturePhoto();
    }

    private void capturePhoto() {
        if (imageCapture == null) return;
        shutter.setEnabled(false);
        File file = captureFile(".jpg");
        ImageCapture.OutputFileOptions output = new ImageCapture.OutputFileOptions.Builder(file).build();
        imageCapture.takePicture(output, getMainExecutor(), new ImageCapture.OnImageSavedCallback() {
            @Override public void onImageSaved(ImageCapture.OutputFileResults result) {
                saveCaptureAndShowFeedback(file, "촬영 사진.jpg", "image/jpeg", false);
            }

            @Override public void onError(ImageCaptureException exception) {
                shutter.setEnabled(true);
                Toast.makeText(CaptureActivity.this, "사진을 저장할 수 없습니다", Toast.LENGTH_SHORT).show();
            }
        });
    }

    private void toggleRecording() {
        if (recording != null) {
            shutter.setEnabled(false);
            recording.stop();
            return;
        }
        if (videoCapture == null || recorder == null) return;
        if (!hasAudioPermission()) {
            requestPermissions(new String[] {Manifest.permission.RECORD_AUDIO}, AUDIO_PERMISSION_REQUEST);
            return;
        }
        startRecording(true);
    }

    private void startRecording(boolean recordAudio) {
        if (recording != null || recorder == null) return;
        File file = captureFile(".mp4");
        PendingRecording pending = recorder.prepareRecording(this, new FileOutputOptions.Builder(file).build());
        if (recordAudio) pending = pending.withAudioEnabled();
        shutter.setEnabled(true);
        shutter.setBackground(shutterBackground(true));
        shutter.setContentDescription("동영상 녹화 중지");
        recording = pending.start(getMainExecutor(), event -> {
            if (event instanceof VideoRecordEvent.Start) {
                Toast.makeText(this, "녹화를 시작했습니다", Toast.LENGTH_SHORT).show();
            } else if (event instanceof VideoRecordEvent.Finalize) {
                VideoRecordEvent.Finalize finalized = (VideoRecordEvent.Finalize) event;
                recording = null;
                if (finalized.hasError()) {
                    shutter.setEnabled(true);
                    shutter.setContentDescription("동영상 녹화 시작");
                    Toast.makeText(this, "동영상을 저장할 수 없습니다", Toast.LENGTH_SHORT).show();
                } else {
                    saveCaptureAndShowFeedback(file, "촬영 동영상.mp4", "video/mp4", true);
                }
            }
        });
    }

    private File captureFile(String suffix) {
        File folder = new File(getFilesDir(), "capture");
        folder.mkdirs();
        return new File(folder, captureBaseId + suffix);
    }

    private void saveCaptureAndShowFeedback(File file, String name, String type, boolean video) {
        showCaptureFeedback(file, video);
        int before = StackStore.load(this).size();
        Uri uri = Uri.parse("content://com.pdg.sharestack.items/capture/" + file.getName()
            + "?name=" + Uri.encode(name) + "&type=" + Uri.encode(type));
        int count = StackStore.receive(this, new Intent(Intent.ACTION_SEND)
            .setType(type)
            .putExtra(Intent.EXTRA_STREAM, uri));
        StackBadge.update(this, count);
        file.delete();
        shutter.setEnabled(true);
        shutter.setContentDescription(videoModeSelected ? "동영상 녹화 시작" : "사진 촬영");
        Toast.makeText(this, count > before ? "스택에 추가했습니다" : "이미 스택에 있는 항목입니다", Toast.LENGTH_SHORT).show();
    }

    private void showCaptureFeedback(File file, boolean video) {
        Bitmap thumbnail = video ? videoThumbnail(file) : photoThumbnail(file);
        if (thumbnail != null) latestCaptureImage.setImageBitmap(thumbnail);
        captureFlash.animate().cancel();
        captureFlash.setAlpha(0f);
        captureFlash.animate().alpha(0.82f).setDuration(75).withEndAction(() ->
            captureFlash.animate().alpha(0f).setDuration(180).start()).start();
        latestCapture.animate().cancel();
        latestCapture.setVisibility(View.VISIBLE);
        latestCapture.setAlpha(0f);
        latestCapture.setScaleX(0.76f);
        latestCapture.setScaleY(0.76f);
        latestCapture.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(180).start();
    }

    private Bitmap photoThumbnail(File file) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(file.getAbsolutePath(), bounds);
        int sampleSize = 1;
        int longest = Math.max(bounds.outWidth, bounds.outHeight);
        while (longest / sampleSize > dp(180)) sampleSize *= 2;
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = sampleSize;
        return BitmapFactory.decodeFile(file.getAbsolutePath(), options);
    }

    private Bitmap videoThumbnail(File file) {
        MediaMetadataRetriever retriever = new MediaMetadataRetriever();
        try {
            retriever.setDataSource(file.getAbsolutePath());
            return retriever.getFrameAtTime(0);
        } catch (RuntimeException ignored) {
            return null;
        } finally {
            try {
                retriever.release();
            } catch (java.io.IOException ignored) { }
        }
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private GradientDrawable roundBackground(int color, int radius) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(color);
        background.setCornerRadius(dp(radius));
        return background;
    }

    private RippleDrawable shutterBackground(boolean video) {
        GradientDrawable outer = new GradientDrawable();
        outer.setShape(GradientDrawable.OVAL);
        outer.setColor(Color.TRANSPARENT);
        outer.setStroke(dp(4), Color.WHITE);
        GradientDrawable inner = new GradientDrawable();
        inner.setShape(video ? GradientDrawable.OVAL : GradientDrawable.OVAL);
        inner.setColor(video ? 0xffe53935 : Color.WHITE);
        LayerDrawable layers = new LayerDrawable(new android.graphics.drawable.Drawable[] {outer, inner});
        layers.setLayerInset(1, dp(9), dp(9), dp(9), dp(9));
        return new RippleDrawable(android.content.res.ColorStateList.valueOf(0x55ffffff), layers, null);
    }
}
