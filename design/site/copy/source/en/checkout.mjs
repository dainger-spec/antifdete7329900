// Payment: our own page, not the processor's (the owner's decision, question 8). The server gets an address from
// the processor's API; the page shows the address, a QR code, the amount, a timer and the status; nobody leaves the
// site; the processor's name isn't shown here. Which coins and networks is still the owner's call (question 13).
// The address, the coin amount, the timer and the dates are sample data.
export default {
  title: 'Payment',
  description: 'Pay for {{name}} in crypto: the address, a QR code, the amount, a timer and the payment status, on our own page.',
  back: 'Plan and payment',
  order: {
    title: 'Order',
    plan: 'Professional plan',
    periods: [['Month', '$59', ''], ['Year', '$590', 'the price of 10 months']],
    rows: [['Paid until now', '29 November 2026'], ['After this payment', '29 December 2026'], ['To pay', '$59']],
    note: 'Your period starts when the network confirms the payment. When it’s close to ending, we remind you by email in advance.',
  },
  pay: {
    title: 'Pay in crypto',
    coinLabel: 'Coin',
    coins: ['USDT', 'BTC', 'ETH'],
    coinsNote: '{{tbd:q13:USDT, BTC or ETH — and on which networks}}',
    rows: [['Network', 'Tron (TRC-20)'], ['Amount', '59.00 USDT']],
    addressLabel: 'Address to send to',
    address: 'TLumenExampLeAddr3ssQ7nS4yE9wq2Xb8u',
    copy: 'Copy',
    qr: 'QR code: the address and the amount',
    timerLabel: 'This address is valid for',
    timer: '14:59',
    exact: 'Send exactly this amount on this network, in one transfer. Sent on another network or in another coin, the payment won’t arrive.',
    statusTitle: 'Status',
    steps: ['Waiting for your transfer', 'Transfer seen — waiting for confirmations', 'Paid — your period is extended'],
    stay: 'No need to reload: the status changes by itself. The receipt comes by email once the payment is confirmed.',
    expired: 'Out of time? Get a new address — the coin amount is recalculated at the current rate; the dollar amount stays the same.',
    newAddress: 'New address',
  },
};
