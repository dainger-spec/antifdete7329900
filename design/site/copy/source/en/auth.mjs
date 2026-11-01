// Sign-in and sign-up as the account server has them (lumen-api-server, docs/SITE_API.md and docs/CONTRACT.md §5):
// email and password; a code from the email only confirms a registration and resets a password. The account is the
// email: no licence-key sign-in, no account without email. A password has at least 10 characters. The server answers a
// sign-up or a reset the same way whether an account with that email exists or not, so the page always says "Check
// your email".
export default {
  title: 'Sign in',
  description: 'Sign in to your {{name}} account with your email and password. Sign-up and password resets use a code from an email.',
  email: {
    title: 'Sign in',
    lead: 'The email and password of your {{name}} account.',
    label: 'Email',
    placeholder: 'you@example.com',
    password: 'Password',
    forgot: 'Forgot your password?',
    action: 'Sign in',
    alt: 'No account yet? [Create one](signup.html)',
  },
  signup: {
    title: 'Create an account',
    lead: 'You need an account to pay, for your devices and for sync. Profiles and their data stay encrypted on your Mac.',
    label: 'Email',
    placeholder: 'you@example.com',
    password: 'Password',
    passwordHint: 'At least 10 characters. This is the account’s password, not your profiles’ master password.',
    agree: 'I accept the [terms of use](terms.html) and the [privacy policy](privacy.html)',
    action: 'Continue',
    alt: 'Already have an account? [Sign in](login.html)',
  },
  code: {
    title: 'Check your email',
    lead: 'We sent an email to **you@example.com**. If there is no account with that email yet, it has a six-digit code — enter it to confirm your registration.',
    label: 'Code from the email',
    action: 'Confirm',
    change: 'Another email',
    hint: 'No email? Check your spam folder. After five wrong tries the code stops working — then start the registration again.',
  },
  reset: {
    title: 'Reset your password',
    lead: 'We send a code to the account’s email. This is the account’s password — your profiles’ master password can’t be reset like this: nobody but you knows it.',
    label: 'Email',
    placeholder: 'you@example.com',
    action: 'Get a code',
    alt: 'Remembered it? [Sign in](login.html)',
  },
  resetCode: {
    title: 'Check your email',
    lead: 'If there is an account with **you@example.com**, we sent a code to it. Enter it and a new password.',
    label: 'Code from the email',
    password: 'New password',
    repeat: 'Repeat new password',
    passwordHint: 'At least 10 characters.',
    action: 'Change password and sign in',
    note: 'Every earlier session on the site ends. Your Macs stay in the account: resetting the password doesn’t unlink them.',
  },
  side: {
    title: 'What the account holds',
    items: [
      ['wallet', 'Your plan, paid period and payments'],
      ['laptop', 'Your devices: their code, when they were last online and how many profiles each has — only the number'],
      ['server', 'Encrypted sync blocks — only you can read them'],
    ],
    note: 'The master password of your profiles is never entered here. It never leaves your Mac — not even to sign in.',
  },
};
