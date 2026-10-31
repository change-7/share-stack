package com.pdg.sharestack;

import java.util.HashSet;
import java.util.Set;

final class AutoReconnect {
    private AutoReconnect() { }

    static boolean samePairing(String host, String token, String pin, String savedHost, String savedToken, String savedPin) {
        return host.equals(savedHost) && token.equals(savedToken) && pin.equals(savedPin);
    }

    static Set<String> readdress(Set<String> queue, String oldHost, String newHost, String pin) {
        String oldPrefix = oldHost + "\t" + pin + "\t";
        String newPrefix = newHost + "\t" + pin + "\t";
        Set<String> result = new HashSet<>();
        for (String entry : queue) result.add(entry.startsWith(oldPrefix) ? newPrefix + entry.substring(oldPrefix.length()) : entry);
        return result;
    }
}
