package com.pdg.sharestack;
import java.util.Set;
import java.util.HashSet;
public class AutoReconnectRegression {
    public static void main(String[] args) {
        Set<String> queue = new HashSet<>(Set.of("old\tpin\tone", "old\tother\ttwo", "else\tpin\tthree"));
        Set<String> moved = AutoReconnect.readdress(queue, "old", "new", "pin");
        assert moved.equals(Set.of("new\tpin\tone", "old\tother\ttwo", "else\tpin\tthree"));
        assert queue.contains("old\tpin\tone");
        assert AutoReconnect.samePairing("old", "secret", "pin", "old", "secret", "pin");
        assert !AutoReconnect.samePairing("old", "secret", "pin", "new", "secret", "pin");
        assert !AutoReconnect.samePairing("old", "secret", "pin", "old", "changed", "pin");
        assert !AutoReconnect.samePairing("old", "secret", "pin", "old", "secret", "other");
    }
}
