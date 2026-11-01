// Sign-in and sign-up as the account server has them (lumen-api-server, docs/SITE_API.md and docs/CONTRACT.md §5):
// email and password; a code from the email only confirms a registration and resets a password. The account is the
// email: no licence-key sign-in, no account without email. A password has at least 10 characters. The server answers a
// sign-up or a reset the same way whether an account with that email exists or not, so the page always says "Check
// your email". The look, as the owner asked, follows Resend's sign-up page in Lumen's own drawing: one column, the mark
// in its tile, «Already have an account? Sign in», a button that stays dim until the fields are filled, small print
// under it. No Google or GitHub sign-in — the server has none; no «send me news» box — there are no marketing emails.
// Accepting the terms is a line under the button, not a checkbox.
export default {
  title: 'Sign in',
  description: 'Sign in to your {{name}} account with your email and password. Sign-up and password resets use a code from an email.',
  home: 'Home',
  note: 'Your profiles’ master password is never entered here: it never leaves your Mac.',
  eye: { show: 'Show password', hide: 'Hide password' },
  email: {
    doc: 'Sign in',
    title: 'Sign in to {{name}}',
    label: 'Email',
    placeholder: 'you@example.com',
    password: 'Password',
    forgot: 'Forgot your password?',
    action: 'Sign in',
    alt: 'No account yet? [Create one](signup.html)',
  },
  signup: {
    doc: 'Sign up',
    title: 'Create a {{name}} account',
    label: 'Email',
    placeholder: 'you@example.com',
    password: 'Password',
    passwordHint: '10 to 256 characters. This is the account’s password, not your profiles’ master password.',
    action: 'Create account',
    legal: 'By creating an account, you accept the [terms of use](terms.html) and the [privacy policy](privacy.html).',
    alt: 'Already have an account? [Sign in](login.html)',
  },
  code: {
    title: 'Check your email',
    lead: 'We sent an email to **you@example.com**. If there is no account with this address yet, the email has a six-digit code. If there already is one, the email tells you how to sign in.',
    label: 'Code from the email',
    action: 'Confirm',
    change: 'Another email',
    hint: 'The code is valid for 15 minutes; you have 5 attempts to enter it. No email? Check your spam folder.',
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
    lead: 'If there is an account with **you@example.com**, we sent a code to it. Enter it and a new password. The code is valid for 15 minutes; you have 5 attempts to enter it.',
    label: 'Code from the email',
    password: 'New password',
    repeat: 'Repeat new password',
    passwordHint: '10 to 256 characters.',
    action: 'Change password and sign in',
    note: 'Every earlier session on the site ends. Your Macs stay in the account: resetting the password doesn’t unlink them.',
  },
};
