package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class Ipv4AddressRulesTest {
    @Test
    public void acceptsOnlyCanonicalRfc1918UnicastAddresses() {
        assertTrue(Ipv4AddressRules.isPrivateUnicast("10.0.0.1"));
        assertTrue(Ipv4AddressRules.isPrivateUnicast("172.20.10.25"));
        assertTrue(Ipv4AddressRules.isPrivateUnicast("192.168.255.254"));
        assertFalse(Ipv4AddressRules.isPrivateUnicast("172.32.0.1"));
        assertFalse(Ipv4AddressRules.isPrivateUnicast("8.8.8.8"));
        assertFalse(Ipv4AddressRules.isPrivateUnicast("192.168.001.2"));
        assertFalse(Ipv4AddressRules.isPrivateUnicast("192.168.1.256"));
        assertFalse(Ipv4AddressRules.isPrivateUnicast("speaker.local"));
        assertFalse(Ipv4AddressRules.isPrivateUnicast(null));
    }
}
