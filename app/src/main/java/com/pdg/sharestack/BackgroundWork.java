package com.pdg.sharestack;

import android.os.Handler;
import android.os.Looper;

import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Runs disk-heavy stack work off the main thread and delivers the result on the UI thread. */
final class BackgroundWork {
    interface Result<T> {
        void onResult(T value, Exception error);
    }

    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "share-stack-work");
        thread.setPriority(Thread.NORM_PRIORITY - 1);
        return thread;
    });

    private BackgroundWork() { }

    static <T> void run(Callable<T> task, Result<T> callback) {
        WORKER.execute(() -> {
            T value = null;
            Exception failure = null;
            try {
                value = task.call();
            } catch (Exception exception) {
                failure = exception;
            }
            T result = value;
            Exception error = failure;
            MAIN.post(() -> callback.onResult(result, error));
        });
    }
}
