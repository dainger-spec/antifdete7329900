// Payment: our own page, not the processor's (the owner's decision, question 8). The server gets an address from
// the processor's API; the page shows the address, a QR code, the amount, a timer and the status; nobody leaves the
// site; the processor's name isn't shown. Minimal: one column — the amount, a month or a year, and the transfer card.
// Which coins and networks is still the owner's call (question 13). The address, coin amount, timer and dates are
// sample data.
export default {
  title: 'Payment',
  description: 'Pay for {{name}} in crypto: the address, a QR code, the amount, a timer and the payment status, on our own page.',
  back: 'Plan and payment',
  plan: 'Professional plan',
  periods: [['Month', '$59', 'Your period runs until 29 December 2026', '59.00 USDT'], ['Year', '$590', 'The price of ten months · your period runs until 29 November 2027', '590.00 USDT']],
  coins: ['USDT', 'BTC', 'ETH'],
  network: 'Tron network (TRC-20)',
  address: 'TLumenExampLeAddr3ssQ7nS4yE9wq2Xb8u',
  copy: 'Copy the address',
  qr: 'QR code: the address and the amount',
  status: 'Waiting for your transfer',
  timer: '14:59',
  timerLabel: 'Address valid for',
  exact: 'Send exactly this amount on this network, in one transfer.',
  after: 'No need to reload: the status changes by itself, and the receipt comes by email.',
  expired: 'Out of time.',
  newAddress: 'Get a new address',
};
