// Home scene "warmup": a profile's hidden window browses Swedish sites while you work.
// The sample is the app's (UISnapshots): profile "Client", a Swedish proxy, page 4 of 12, 84 cookies; the
// sites are the ready-made "Sweden" list (WarmUpPreset.swift). The window's strings are the app's.
export default {
  title: 'Warm-up',
  head: ['Warm-up runs', 'while you work.'],
  lead: 'A profile browses the sites of its proxy’s country and collects cookies — in a hidden window. Nothing opens in front of you.',
  short: 'The profile browses its proxy country’s sites — in a hidden window.',
  picture: 'Example: the profile “Client”, with a proxy in Sweden, warms up on Swedish sites — google.se, aftonbladet.se, svt.se, dn.se. It is on page 4 of 12, with 84 cookies collected.',
  profile: 'Client',
  hidden: 'Hidden window',
  unit: 'cookies collected',
  page: 'Page {n} of {total}',
  facts: [
    '**26 countries.** A ready-made list of local sites for each, in its own language. The app takes the country from the proxy.',
    '**Like a reader.** Normally {{nb:10–35 seconds}} a page, scrolling. In Quick mode {{nb:4–12 s}}, in Deep {{nb:25–90 s}}.',
    '**Only looks.** It types nothing, submits nothing, buys nothing. It can also start by itself, on a schedule.',
  ],
};
