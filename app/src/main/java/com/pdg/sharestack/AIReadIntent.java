package com.pdg.sharestack;

final class AIReadIntent {
    enum Phase { WAITING, TRANSFERRING, READY, REVOKED, FAILED }
    final String id, itemID, peerPin;
    long revision, changedAt;
    boolean allowed;
    Phase phase = Phase.REVOKED;
    int progress;
    String error = "";

    AIReadIntent(String id, String itemID, String peerPin) {
        this.id = id;
        this.itemID = itemID;
        this.peerPin = peerPin;
    }

    void choose(boolean enabled, long now) {
        revision = Math.addExact(revision, 1);
        allowed = enabled;
        changedAt = now;
        phase = Phase.WAITING;
        progress = 0;
        error = "";
    }

    boolean pending() { return phase == Phase.WAITING || phase == Phase.TRANSFERRING || phase == Phase.FAILED; }
    boolean graceElapsed(long now) { return !allowed || now - changedAt >= 700; }

    boolean update(long expectedRevision, Phase next, int percent, String message) {
        if (revision != expectedRevision) return false;
        phase = next;
        progress = Math.max(0, Math.min(100, percent));
        error = message;
        return true;
    }

    boolean acknowledge(long responseRevision, boolean responseAllowed, boolean ready) {
        if (revision != responseRevision || allowed != responseAllowed || allowed && !ready) return false;
        return update(responseRevision, allowed ? Phase.READY : Phase.REVOKED, allowed ? 100 : 0, "");
    }

    String status() {
        switch (phase) {
            case READY: return "AI 읽기 준비 완료";
            case REVOKED: return "AI 읽기 해제 완료";
            case TRANSFERRING: return "전송 중 · " + progress + "%";
            case FAILED: return allowed ? "실패 · 재시도 대기" : "해제 실패 · 동기화 대기";
            default: return allowed ? "전송 대기" : "해제 동기화 대기";
        }
    }
}
