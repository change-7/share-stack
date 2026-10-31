package com.pdg.sharestack;

public final class AIReadIntentRegression {
    public static void main(String[] args) {
        AIReadIntent intent = new AIReadIntent("consent", "item.txt", "paired-mac");
        assert !intent.allowed && !intent.pending();
        intent.choose(true, 1000);
        assert intent.allowed && intent.pending() && intent.revision == 1;
        assert !intent.graceElapsed(1699) && intent.graceElapsed(1700);
        assert !intent.acknowledge(1, true, false);
        assert intent.pending();
        intent.choose(false, 1800);
        assert !intent.allowed && intent.pending();
        assert !intent.update(1, AIReadIntent.Phase.READY, 100, "");
        assert !intent.acknowledge(1, true, true);
        assert intent.phase == AIReadIntent.Phase.WAITING;
        assert intent.acknowledge(2, false, false);
        assert intent.phase == AIReadIntent.Phase.REVOKED && !intent.pending();
        intent.choose(true, 2000);
        assert !intent.acknowledge(2, false, false);
        assert intent.acknowledge(3, true, true);
        assert intent.phase == AIReadIntent.Phase.READY && !intent.pending();
        intent.choose(false, 3000);
        intent.update(4, AIReadIntent.Phase.FAILED, 0, "offline");
        assert intent.pending() && !intent.allowed;
        assert intent.status().contains("해제") && !intent.status().contains("완료");
        System.out.println("PASS: grace, default-off, remote confirmation, stale completion rejection and offline revoke remains pending");
    }
}
