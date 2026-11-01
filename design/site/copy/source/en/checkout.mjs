// Payment: our own page, not the processor's (the owner's decision, question 8), as the account server describes it
// (lumen-api-server, docs/SITE_API.md §5): an invoice with the address, the amount (exactly the server's string), a QR
// code, the network and a deadline — the rate in a coin is held for 30 minutes; the page polls the invoice and never asks
// for a reload; the processor's name appears nowhere (nor is it in the server's answers). «Order» (the plan, month or
// year, the total, the period) and «Transfer» (the coin, the QR code, the amount and the address with copy buttons, the
// network, the rule for the transfer — in the server's words, prominent, not in small print, the status). Coins come from GET /v1/plans, three by
// default: USDT on Tron, BTC and ETH (the owner sets the list, question 13); the list gets a search field when there are
// more than six. The sample is a Team plan, as in the account; amounts, addresses, the timer and dates are samples.
export default {
  title: 'Payment',
  description: 'Pay for {{name}} in crypto: the address, a QR code, the amount, a timer and the payment status, on our own page.',
  back: 'Account',
  brand: 'Pay',
  plan: 'Team plan',
  periods: [['Month', '$149', 'Your period runs until 29 December 2026'], ['Year', '$1490', 'The price of ten months · your period runs until 29 November 2027']],
  order: 'Order',
  transfer: 'Transfer',
  period: 'Period',
  total: 'Total',
  amount: 'Amount',
  networkLabel: 'Network',
  address: 'Address',
  copyAmount: 'Copy the amount',
  coinLabel: 'Coin and network',
  coinSearch: 'Coin or network',
  coinEmpty: 'Nothing found',
  coins: [
    { t: 'USDT', n: 'Tether', net: 'Tron (TRC-20)', m: '149.000000', y: '1490.000000', a: 'TLumenExampLeAddr3ssQ7nS4yE9wq2Xb8u' },
    { t: 'BTC', n: 'Bitcoin', net: 'Bitcoin', m: '0.00154', y: '0.0154', a: 'bc1qexample0lumen7x9k2m4p6r8t0v2w4y6z8a0c2e4' },
    { t: 'ETH', n: 'Ethereum', net: 'Ethereum', m: '0.0434', y: '0.434', a: '0x2e8f0a4c6b8d0f2a4c6e8a0c2e4f6a8c0e2a4c6e' },
  ],
  copy: 'Copy the address',
  qr: 'QR code: the address and the amount',
  status: 'Waiting for your transfer',
  timer: '29:59',
  timerLabel: 'Rate held for',
  exact: 'Send exactly {amount} {ticker} on {network} to this address, in one transfer. **If you pay from an exchange, add its withdrawal fee on top**: the whole amount must arrive, or you’ll have to send the rest.',
  after: 'No need to reload: the status changes by itself, and the receipt comes by email.',
  expired: 'Out of time: the rate in a coin is held for 30 minutes.',
  newAddress: 'Get a new address',
};
