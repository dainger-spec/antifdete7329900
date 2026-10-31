// Payment: our own page, not the processor's (the owner's decision, question 8). The server gets an address from
// the processor's API; the page shows the address, a QR code, the amount, a timer and the status; nobody leaves the
// site; the processor's name isn't shown. Minimal: one column — the amount, a month or a year, and the transfer card.
// The coin is picked from a searchable list: there will be many coins and networks. Which ones is still the owner's
// call (question 13); the list, coin amounts, addresses, timer and dates are sample data.
export default {
  title: 'Payment',
  description: 'Pay for {{name}} in crypto: the address, a QR code, the amount, a timer and the payment status, on our own page.',
  back: 'Plan and payment',
  plan: 'Professional plan',
  periods: [['Month', '$59', 'Your period runs until 29 December 2026'], ['Year', '$590', 'The price of ten months · your period runs until 29 November 2027']],
  coinLabel: 'Coin and network',
  coinSearch: 'Coin or network',
  coinEmpty: 'Nothing found',
  network: 'On {net}',
  coins: [
    { t: 'USDT', n: 'Tether', net: 'Tron (TRC-20)', m: '59.00', y: '590.00', a: 'TLumenExampLeAddr3ssQ7nS4yE9wq2Xb8u' },
    { t: 'USDT', n: 'Tether', net: 'Ethereum (ERC-20)', m: '59.00', y: '590.00', a: '0x4c7e9a1f2b3d5e6f7081a2b3c4d5e6f708192a3b' },
    { t: 'USDT', n: 'Tether', net: 'TON', m: '59.00', y: '590.00', a: 'UQLumenExample_9kVz2fQ7xR4mW8pB3nT6yH1cJ5dG0' },
    { t: 'USDC', n: 'USD Coin', net: 'Ethereum (ERC-20)', m: '59.00', y: '590.00', a: '0x91b3c5d7e9f1a3b5c7d9e1f3a5b7c9d1e3f5a7b9' },
    { t: 'USDC', n: 'USD Coin', net: 'Solana', m: '59.00', y: '590.00', a: '7xKLumenExample3Pq9wZ5rT2nV8bY4mJ6cH1dF0gS' },
    { t: 'BTC', n: 'Bitcoin', net: 'Bitcoin', m: '0.00061', y: '0.0061', a: 'bc1qexample0lumen7x9k2m4p6r8t0v2w4y6z8a0c2e4' },
    { t: 'ETH', n: 'Ethereum', net: 'Ethereum', m: '0.0172', y: '0.172', a: '0x2e8f0a4c6b8d0f2a4c6e8a0c2e4f6a8c0e2a4c6e' },
    { t: 'SOL', n: 'Solana', net: 'Solana', m: '0.33', y: '3.3', a: '9mLumenExample5Rq2wZ8rT4nV1bY7mJ3cH6dF2gK' },
    { t: 'TON', n: 'Toncoin', net: 'TON', m: '11.8', y: '118', a: 'UQLumenExample_4hTq8nR2xW6mZ9pC5vB1yK3dF7gJ' },
    { t: 'LTC', n: 'Litecoin', net: 'Litecoin', m: '0.71', y: '7.1', a: 'ltc1qexample0lumen5v8k2m4p6r8t0v2w4y6z8a0c' },
    { t: 'TRX', n: 'TRON', net: 'Tron', m: '245.6', y: '2456', a: 'TLumenExampLeTrx7q9wZ5rT2nV8bY4mJ6cH1' },
    { t: 'BNB', n: 'BNB', net: 'BNB Smart Chain (BEP-20)', m: '0.098', y: '0.98', a: '0x6a0c2e4f6a8c0e2a4c6e8a0c2e4f6a8c0e2a4c6e' },
    { t: 'DOGE', n: 'Dogecoin', net: 'Dogecoin', m: '352.4', y: '3524', a: 'DLumenExampLe7q9wZ5rT2nV8bY4mJ6cH1d' },
    { t: 'POL', n: 'Polygon', net: 'Polygon', m: '141.2', y: '1412', a: '0x3b5d7f9a1c3e5a7c9e1a3c5e7a9c1e3a5c7e9a1c' },
  ],
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
