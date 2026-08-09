package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertEquals;

import java.math.BigInteger;
import java.security.interfaces.RSAPublicKey;
import org.junit.Test;

public final class SshKeyManagerTest {
    @Test
    public void copiedPairingKeyIsBareTwoColumnOpenSshLine() {
        RSAPublicKey key = new FixedRsaPublicKey(
                new BigInteger(1, new byte[] {(byte) 0x80, 1}),
                BigInteger.valueOf(65_537L));

        assertEquals(
                "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAAwCAAQ==",
                SshKeyManager.formatPublicKeyLine(key));
    }

    private static final class FixedRsaPublicKey implements RSAPublicKey {
        private static final long serialVersionUID = 1L;

        private final BigInteger modulus;
        private final BigInteger exponent;

        FixedRsaPublicKey(BigInteger modulus, BigInteger exponent) {
            this.modulus = modulus;
            this.exponent = exponent;
        }

        @Override
        public BigInteger getPublicExponent() {
            return exponent;
        }

        @Override
        public BigInteger getModulus() {
            return modulus;
        }

        @Override
        public String getAlgorithm() {
            return "RSA";
        }

        @Override
        public String getFormat() {
            return null;
        }

        @Override
        public byte[] getEncoded() {
            return null;
        }
    }
}
