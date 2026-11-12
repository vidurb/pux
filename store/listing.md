# Store listing copy

Paste each block as it is. Limits are the stores' own, and `store/README.md` says how to check them. The examples use the fictional Northwind Bank: both stores can reject listings that name a real bank.

Don't mention Android in the App Store copy or iPhone in the Play copy; App Review rejects references to other mobile platforms. The desktop apps are fine to mention.

## Google Play

### App name (30)

```text
pux: bank OTPs anywhere
```

### Short description (80)

```text
Get bank OTPs from email on every phone and computer, even with no signal.
```

### Full description (4000)

```text
pux gets your bank's one-time passwords to you when the SMS can't: abroad without roaming, in a basement with no signal, or with your SIM in a different phone.

Many banks send each OTP by email as well as by SMS. Forward just those emails to your private pux address, and pux finds the code and sends it to your devices over Wi-Fi or any other internet connection. It shows up as a notification within seconds: "OTP from Northwind Bank, 482913".

HOW IT WORKS
• Create a relay in the app. Its encryption keys are made on your phone.
• Set up a filter in your email that forwards only your bank's OTP emails to the relay's address. The app shows the steps for Gmail and Outlook.com.
• Each code is encrypted for your devices before it leaves the server. Add another phone by scanning a QR code, or your computer with the free desktop apps for macOS and Linux.

PRIVATE BY DESIGN
• End-to-end encrypted: the server seals each code with your devices' public key and can't open it.
• No account: no name, email address, phone number or password.
• Emails are read in memory to find the code, then dropped. They are never stored.
• No analytics, no ads, no trackers.
• Delete your relay, its devices and any codes waiting for them from the server, in the app, at any time.
• Open source under the AGPL. Read the code, or run your own server.

GOOD TO KNOW
• pux only works if your bank also sends OTPs by email.
• If the sender's DKIM signature doesn't check out, the notification says the code is unverified.
• Android pauses apps that go unused for a few months, and a paused app can't receive codes. The app shows how to turn that off if you rely on pux for rare codes.
• You must be 18 or older to use pux.

Privacy policy: https://pux.vidur.xyz/privacy
Source code: https://github.com/vidurb/pux
```

## App Store

### Name (30)

```text
pux: bank OTPs anywhere
```

### Subtitle (30)

```text
Bank OTPs, even with no signal
```

### Promotional text (170)

Can be changed without a new build.

```text
Abroad without roaming, or no signal indoors? pux takes the OTP from your bank's email and sends it to every device you add, end-to-end encrypted.
```

### Description (4000)

```text
pux gets your bank's one-time passwords to you when the SMS can't: abroad without roaming, in a basement with no signal, or with your SIM in a different phone.

Many banks send each OTP by email as well as by SMS. Forward just those emails to your private pux address, and pux finds the code and sends it to your devices over Wi-Fi or any other internet connection. It shows up as a notification within seconds: "OTP from Northwind Bank, 482913".

HOW IT WORKS
• Create a relay in the app. Its encryption keys are made on your iPhone.
• Set up a filter in your email that forwards only your bank's OTP emails to the relay's address. The app shows the steps for Gmail and Outlook.com.
• Each code is encrypted for your devices before it leaves the server. Add another phone by scanning a QR code, or your computer with the free desktop apps for macOS and Linux.

PRIVATE BY DESIGN
• End-to-end encrypted: the server seals each code with your devices' public key and can't open it. Apple's push service carries only the sealed code and a "New code" placeholder, which your iPhone replaces after decrypting.
• No account: no name, email address, phone number or password.
• Emails are read in memory to find the code, then dropped. They are never stored.
• No analytics, no ads, no trackers.
• Delete your relay, its devices and any codes waiting for them from the server, in the app, at any time.
• Open source under the AGPL. Read the code, or run your own server.

GOOD TO KNOW
• pux only works if your bank also sends OTPs by email.
• If the sender's DKIM signature doesn't check out, the notification says the code is unverified.
• You must be 18 or older to use pux.
```

### Keywords (100)

Comma-separated, no spaces after commas. The name and subtitle are indexed already, so these avoid repeating them.

```text
one-time password,2fa,verification,sms,roaming,travel,email,forward,encrypted,relay,code,abroad
```

### URLs

| Field | Value |
|-------|-------|
| Privacy policy | `https://pux.vidur.xyz/privacy` |
| Support | `https://github.com/vidurb/pux/issues` |
| Marketing | `https://pux.vidur.xyz` |
