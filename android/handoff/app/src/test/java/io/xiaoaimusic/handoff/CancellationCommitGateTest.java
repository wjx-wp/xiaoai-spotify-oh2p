package io.xiaoaimusic.handoff;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.Test;

public final class CancellationCommitGateTest {
    @Test
    public void cancellationBeforeCommitPreventsMutation() {
        CancellationCommitGate gate = new CancellationCommitGate();
        assertTrue(gate.cancel() == CancellationCommitGate.CancelResult.CANCELLED);
        AtomicBoolean mutated = new AtomicBoolean(false);
        assertThrows(InterruptedException.class,
                () -> gate.commit(() -> mutated.set(true)));
        assertFalse(mutated.get());
    }

    @Test
    public void commitAndCancellationHaveOneLinearOrder() throws Exception {
        CancellationCommitGate gate = new CancellationCommitGate();
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        AtomicBoolean committed = new AtomicBoolean(false);
        Thread commit = new Thread(() -> {
            try {
                gate.commit(() -> {
                    entered.countDown();
                    assertTrue(release.await(2, TimeUnit.SECONDS));
                    committed.set(true);
                });
            } catch (Exception failure) {
                throw new AssertionError(failure);
            }
        });
        commit.start();
        assertTrue(entered.await(2, TimeUnit.SECONDS));

        AtomicBoolean cancelled = new AtomicBoolean(false);
        Thread cancel = new Thread(() -> cancelled.set(
                gate.cancel() == CancellationCommitGate.CancelResult.CANCELLED));
        cancel.start();
        Thread.sleep(25L);
        assertFalse(cancelled.get());
        release.countDown();
        commit.join(2_000L);
        cancel.join(2_000L);
        assertTrue(committed.get());
        assertTrue(cancelled.get());
    }

    @Test
    public void finishedOperationCannotBeCancelledOrCommitted() {
        CancellationCommitGate gate = new CancellationCommitGate();
        assertTrue(gate.finish());
        assertTrue(gate.cancel() == CancellationCommitGate.CancelResult.ALREADY_TERMINAL);
        assertThrows(InterruptedException.class, () -> gate.commit(() -> {}));
    }

    @Test
    public void cancellationDuringRemoteCommitKeepsLocalPendingForReconciliation()
            throws Exception {
        CancellationCommitGate gate = new CancellationCommitGate();
        gate.beginRemoteCommit();
        assertTrue(gate.cancel()
                == CancellationCommitGate.CancelResult.REMOTE_RESULT_UNCERTAIN);
        AtomicBoolean cleared = new AtomicBoolean(false);
        assertThrows(InterruptedException.class,
                () -> gate.commitRemoteSuccess(() -> cleared.set(true)));
        assertFalse(cleared.get());
        assertFalse(gate.finish());
    }
}
