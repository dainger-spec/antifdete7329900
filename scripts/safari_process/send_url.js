// osascript -l JavaScript send_url.js <pid> <url>
// Sends the 'GURL' Apple Event (open location) to one process, chosen by PID. Two processes with
// the same bundle identifier cannot be told apart by name, so this is how a URL reaches a Safari
// started directly from its executable.
ObjC.import('Foundation');

function run(argv) {
  const pid = parseInt(argv[0], 10);
  const url = argv[1];
  const GURL = 0x4755524c; // 'GURL'
  const DIRECT = 0x2d2d2d2d; // '----', keyDirectObject
  const target = $.NSAppleEventDescriptor.descriptorWithProcessIdentifier(pid);
  const event = $.NSAppleEventDescriptor.appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(
    GURL, GURL, target, -1, 0);
  event.setParamDescriptorForKeyword($.NSAppleEventDescriptor.descriptorWithString(url), DIRECT);
  const error = Ref();
  const reply = event.sendEventWithOptionsTimeoutError(3 /* wait for reply */, 15, error);
  if (!reply || reply.isNil()) {
    const e = error[0];
    return 'error: ' + (e && !e.isNil() ? e.localizedDescription.js : 'no reply');
  }
  return 'sent';
}
