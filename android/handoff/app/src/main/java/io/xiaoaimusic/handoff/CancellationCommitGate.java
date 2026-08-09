package io.xiaoaimusic.handoff;

/** Linearizes cancellation/finish against short irreversible local commits. */
final class CancellationCommitGate {
    enum CancelResult { CANCELLED, REMOTE_RESULT_UNCERTAIN, ALREADY_TERMINAL }

    private enum State {
        ACTIVE,
        REMOTE_IN_FLIGHT,
        REMOTE_COMMITTED,
        CANCELLED,
        CANCELLED_REMOTE_UNCERTAIN,
        FINISHED
    }

    @FunctionalInterface
    interface CommitAction {
        void run() throws Exception;
    }

    private State state = State.ACTIVE;

    synchronized void ensureActive() throws InterruptedException {
        if (state != State.ACTIVE || Thread.currentThread().isInterrupted()) {
            throw new InterruptedException("operation was cancelled");
        }
    }

    synchronized void commit(CommitAction action) throws Exception {
        ensureActive();
        action.run();
    }

    synchronized void beginRemoteCommit() throws InterruptedException {
        ensureActive();
        state = State.REMOTE_IN_FLIGHT;
    }

    synchronized void commitRemoteSuccess(CommitAction localAcknowledgement) throws Exception {
        if (state == State.CANCELLED_REMOTE_UNCERTAIN) {
            throw new InterruptedException("remote result must be reconciled on retry");
        }
        if (state != State.REMOTE_IN_FLIGHT) {
            throw new IllegalStateException("no remote commit is in flight");
        }
        try {
            localAcknowledgement.run();
            state = State.REMOTE_COMMITTED;
        } catch (Exception failure) {
            state = State.ACTIVE;
            throw failure;
        }
    }

    synchronized void remoteFailed() {
        if (state == State.REMOTE_IN_FLIGHT) state = State.ACTIVE;
    }

    synchronized CancelResult cancel() {
        if (state == State.ACTIVE) {
            state = State.CANCELLED;
            return CancelResult.CANCELLED;
        }
        if (state == State.REMOTE_IN_FLIGHT) {
            state = State.CANCELLED_REMOTE_UNCERTAIN;
            return CancelResult.REMOTE_RESULT_UNCERTAIN;
        }
        return CancelResult.ALREADY_TERMINAL;
    }

    synchronized boolean finish() {
        if (state != State.ACTIVE && state != State.REMOTE_COMMITTED) return false;
        state = State.FINISHED;
        return true;
    }
}
