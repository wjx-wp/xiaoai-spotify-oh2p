package io.xiaoaimusic.handoff;

final class Ipv4AddressRules {
    static boolean isPrivateUnicast(String value) {
        if (value == null || value.length() < 7 || value.length() > 15) return false;
        String[] parts = value.split("\\.", -1);
        if (parts.length != 4) return false;
        int[] octets = new int[4];
        for (int index = 0; index < parts.length; index++) {
            String part = parts[index];
            if (part.isEmpty() || part.length() > 3
                    || (part.length() > 1 && part.charAt(0) == '0')) return false;
            int parsed = 0;
            for (int character = 0; character < part.length(); character++) {
                char current = part.charAt(character);
                if (current < '0' || current > '9') return false;
                parsed = parsed * 10 + current - '0';
            }
            if (parsed > 255) return false;
            octets[index] = parsed;
        }
        return octets[0] == 10
                || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
                || (octets[0] == 192 && octets[1] == 168);
    }

    private Ipv4AddressRules() {}
}
