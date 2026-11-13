package xyz.vidur.pux.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.vidur.pux.api.likelyNoRequestReachedServer
import java.net.UnknownHostException

class RemovalFailureTest {
    @Test fun retryInvokesOnlyTheOriginalAction() {
        for (action in RemovalAction.entries) {
            val calls = mutableListOf<RemovalAction>()
            retryRemoval(action,
                forget = { calls.add(RemovalAction.FORGET) },
                remove = { calls.add(RemovalAction.REMOVE_DEVICE) },
                delete = { calls.add(RemovalAction.DELETE_RELAY) }
            )
            assertEquals(listOf(action), calls)
        }
    }

    @Test fun unknownHostIsTreatedAsNoRequestReachedServer() {
        assertTrue(likelyNoRequestReachedServer(UnknownHostException("offline")))
    }

    @Test fun connectExceptionIsNotTreatedAsNoRequestReachedServer() {
        assertFalse(likelyNoRequestReachedServer(java.net.ConnectException("refused")))
    }
}
