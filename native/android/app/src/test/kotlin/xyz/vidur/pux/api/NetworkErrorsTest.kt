package xyz.vidur.pux.api

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.UnknownHostException
import javax.net.ssl.SSLException

class NetworkErrorsTest {
    @Test fun unknownHostIsTreatedAsServerUnreachable() {
        assertTrue(likelyNoRequestReachedServer(UnknownHostException("no.dns.example")))
    }

    @Test fun postResponseTlsFailureDoesNotMarkUnreachable() {
        assertFalse(likelyNoRequestReachedServer(SSLException("Certificate chain not trusted")))
    }

    @Test fun handshakeMessageAloneDoesNotMarkUnreachable() {
        assertFalse(likelyNoRequestReachedServer(SSLException("SSL handshake aborted")))
    }

    @Test fun afterSuccessfulDeleteHandshakeAmbiguityKeepsPendingIntent() {
        assertFalse(remoteRemovalRequestLikelyUnsent(SSLException("handshake timed out"), remoteRemovalCompleted = true))
    }

    @Test fun beforeDeleteUnknownHostClearsPendingOnCancelSemantics() {
        assertTrue(remoteRemovalRequestLikelyUnsent(UnknownHostException("no.dns.example"), remoteRemovalCompleted = false))
    }
}
