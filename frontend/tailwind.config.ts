import type { Config } from 'tailwindcss';

// Farbwelt nach den Referenzbildern: nahezu schwarzes Blau, Cyan/Blau-Akzente,
// Türkis/Grün für positive Zustände, Rot für Bremse und Fehler.
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        bg: { 0: '#03060c', 1: '#060b15', 2: '#0a111e', 3: '#0e1828', 4: '#132036' },
        line: { DEFAULT: '#1a2942', strong: '#25395a', glow: '#2f5c9e' },
        ink: { DEFAULT: '#e9f0fb', 2: '#a6b4cc', 3: '#6f80a0', 4: '#4a5a78' },
        accent: { DEFAULT: '#2f8bff', cyan: '#22d3ee', deep: '#1c4fd8', soft: '#12305e' },
        ok: { DEFAULT: '#1de9b0', 2: '#22c55e', soft: '#0b3b33' },
        warn: { DEFAULT: '#f6b73c', soft: '#3d2e0c' },
        danger: { DEFAULT: '#ff3d4a', 2: '#e11d2e', soft: '#3a0c12' },
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'Segoe UI', 'Roboto', 'sans-serif'],
      },
      borderRadius: { card: '16px', pad: '22px' },
      boxShadow: {
        card: '0 1px 0 rgba(255,255,255,0.02) inset, 0 8px 24px rgba(0,0,0,0.35)',
        'glow-accent': '0 0 0 1px rgba(47,139,255,0.55), 0 0 22px rgba(47,139,255,0.25)',
        'glow-ok': '0 0 0 1px rgba(29,233,176,0.6), 0 0 26px rgba(29,233,176,0.22)',
        'glow-danger': '0 0 0 1px rgba(255,61,74,0.6), 0 0 26px rgba(255,61,74,0.25)',
      },
      keyframes: {
        pulseSoft: { '0%,100%': { opacity: '1' }, '50%': { opacity: '0.45' } },
      },
      animation: { 'pulse-soft': 'pulseSoft 1.6s ease-in-out infinite' },
    },
  },
  plugins: [],
} satisfies Config;
