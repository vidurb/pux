package xyz.vidur.pux.api

import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/** True when the client likely never delivered an HTTP request to the server. */
fun likelyNoRequestReachedServer(error: Throwable): Boolean {
    var current: Throwable? = error
    while (current != null) {
        if (current is UnknownHostException || current is NoRouteToHostException) {
            return true
        }
        current = current.cause
    }
    return error is SocketTimeoutException &&
        error.message?.contains("connect", ignoreCase = true) == true
}

/**
 * For remote removal, only treat the server as unreachable when the HTTP removal did not complete
 * and the failure looks like a pre-request transport error (not post-response TLS, etc.).
 */
fun remoteRemovalRequestLikelyUnsent(error: Throwable, remoteRemovalCompleted: Boolean): Boolean {
    if (remoteRemovalCompleted) return false
    return likelyNoRequestReachedServer(error)
}
