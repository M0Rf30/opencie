# Signing on a computer with your phone's NFC

OpenCIE can use an NFC phone as the card reader for a signature started on a
computer. On the computer the feature is called **Sign with phone**
(Italian UI: *Firma con telefono*); on the phone it is **Sign for a desktop**
(*Firma per un desktop*).

## When to use it

Use it when the computer has no contactless (NFC) reader. The CIE talks only
over the contactless interface, so a contact smart-card slot cannot read it.
Some laptops have only such a slot: for example, many Dell units with
ControlVault 3 expose just a "Contacted SmartCard" reader. If your computer has
a contactless PC/SC reader, you don't need this.

## Requirements

- OpenCIE on the computer (Linux, Windows or macOS) and on an Android phone
  with NFC.
- Your CIE enrolled in OpenCIE on the phone, and its PIN.
- The two devices must be able to reach each other. The connection is a direct
  WebRTC data channel that uses STUN only (no TURN/relay server), so it works
  best when both are on the same network. Strict NAT or corporate networks may
  prevent it from connecting.

## Steps

1. On the computer open **Sign** and pick the file to sign.
2. Click **Sign with phone** (*Firma con telefono*). A QR code appears.
3. On the phone open OpenCIE, tap **Sign for a desktop** (*Firma per un
   desktop*) and scan that code.
4. The phone shows a reply code (a second QR code). Get it to the computer:
   - **macOS:** hold the phone screen up to the webcam.
   - **Linux / Windows:** webcam scanning isn't available. On the phone tap
     **Copy reply code** (*Copia codice risposta*), move the text to the
     computer (see below), then click **Paste from clipboard** (*Incolla dagli
     appunti*). Alternatively take a screenshot of the reply QR, transfer it
     to the computer and use **Open QR image…** (*Apri immagine QR…*), or drag
     and drop the image onto the window.
5. Both screens show four words. Check that they match, then confirm on both
   devices ("They match").
6. The phone shows the document. Review it, enter your PIN and hold the CIE to
   the back of the phone when asked.
7. The signed `.p7m` is sent back, verified on the computer and saved next to
   the original file.

Documents are limited to 50 MiB.

### Moving the reply code from phone to PC (Linux)

- A clipboard-sync tool such as KDE Connect or GSConnect: copy on the phone,
  paste on the PC.
- Send the code to yourself (messaging app, email, notes) and copy it on the
  PC.
- Take a screenshot of the reply QR and transfer it to the PC (file transfer,
  KDE Connect, cloud drive), then open or drop it as above.

## Security notes

- The pairing is end-to-end encrypted: an ephemeral X25519 key exchange, with
  the data channel sealed using ChaCha20-Poly1305. No server sees the content.
- The document itself travels to the phone, in chunks, over that encrypted
  channel. The phone checks its SHA-256 against the descriptor and shows a
  preview rendered from the bytes it actually received, then signs that
  document. The computer verifies the signed file before saving it.
- The four words (short authentication string) are derived from the key
  exchange. If someone swapped one of the QR codes, the words would differ, so
  never confirm if they don't match: choose "They don't match".
- Pairing codes are short-lived: a code is accepted for about 90 seconds after
  it was created (with up to 2 minutes of clock difference between the two
  devices tolerated). If it expires, click **Refresh code** (*Aggiorna
  codice*) and start again.
- The connection uses public STUN servers only to discover network addresses;
  document data never goes through them.

## Troubleshooting

- **The QR is grey or empty.** Fixed in a newer release; update OpenCIE. If
  you see "The pairing code is too large…", click **Refresh code**.
- **"This isn't an OpenCIE pairing code."** (*Questo non è un codice di
  abbinamento OpenCIE.*) You scanned a different QR, typically the one shown by
  a website's CIE login page. Logging in to websites isn't an OpenCIE feature:
  use the official app for CIE website login. For signing, scan the code shown
  by **Sign with phone** on the computer.
- **"Webcam scanning isn't available on this system"** (*La scansione con
  webcam non è disponibile su questo sistema*). Expected on Linux and Windows.
  Use **Paste from clipboard**, **Open QR image…** or drag and drop.
- **"Webcam unavailable"** (*Webcam non disponibile*) on macOS. Check the
  camera permission for OpenCIE, or use the paste/image options.
- **"This isn't a valid OpenCIE reply code."** Make sure you copied the whole
  code, or click **Refresh code** and pair again. A leftover code from an
  earlier attempt, or a code that has expired, is also rejected.
- **"No QR code found in this image."** Use a sharper, larger screenshot that
  shows the whole reply QR.
- **The connection never completes.** Put both devices on the same Wi-Fi/LAN,
  turn off VPNs and guest-network isolation, and retry. Without a relay,
  restrictive NAT or corporate firewalls can block the direct channel.
