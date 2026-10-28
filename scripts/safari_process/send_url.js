// osascript -l JavaScript send_url.js <pid> <url>
// osascript -l JavaScript send_url.js <pid> --quit
// Sends the 'GURL' Apple Event (open location), or 'quit', to one process, chosen by PID. Two
// processes with the same bundle identifier cannot be told apart by name, so this is how a URL
// reaches a Safari started directly from its executable, and how it is asked to quit (and save
// its cookies) rather than killed.
ObjC.import('Foundation');

function run(argv) {
  const pid = parseInt(argv[0], 10);
  const url = argv[1];
  const GURL = 0x4755524c; // 'GURL'
  const AEVT = 0x61657674, QUIT = 0x71756974; // 'aevt', 'quit'
  const DIRECT = 0x2d2d2d2d; // '----', keyDirectObject
  const quit = url === '--quit';
  const target = $.NSAppleEventDescriptor.descriptorWithProcessIdentifier(pid);
  const event = $.NSAppleEventDescriptor.appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(
    quit ? AEVT : GURL, quit ? QUIT : GURL, target, -1, 0);
  if (!quit) event.setParamDescriptorForKeyword($.NSAppleEventDescriptor.descriptorWithString(url), DIRECT);
  const error = Ref();
  const reply = event.sendEventWithOptionsTimeoutError(3 /* wait for reply */, 15, error);
  if (!reply || reply.isNil()) {
    const e = error[0];
    return 'error: ' + (e && !e.isNil() ? e.localizedDescription.js : 'no reply');
  }
  return 'sent';
}
