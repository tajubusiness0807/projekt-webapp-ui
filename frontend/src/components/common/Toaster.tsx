import { AlertTriangle, CheckCircle2, Info, XCircle } from 'lucide-react';
import { useToasts } from '../../stores/toastStore';

export function Toaster() {
  const toasts = useToasts((s) => s.toasts);
  const dismiss = useToasts((s) => s.dismiss);
  return (
    <div className="pointer-events-none fixed inset-x-0 top-16 z-50 flex flex-col items-center gap-2 px-3 sm:top-20" aria-live="polite">
      {toasts.map((t) => {
        const Icon = { info: Info, success: CheckCircle2, warning: AlertTriangle, error: XCircle }[t.kind];
        const style = {
          info: 'border-accent/40 text-ink',
          success: 'border-ok/50 text-ok',
          warning: 'border-warn/60 text-warn',
          error: 'border-danger/60 text-[#ffb3b8]',
        }[t.kind];
        return (
          <button
            type="button"
            key={t.id}
            onClick={() => dismiss(t.id)}
            className={`pointer-events-auto flex max-w-lg items-start gap-2.5 rounded-xl border bg-bg-2/95 px-4 py-2.5 text-left text-sm shadow-card backdrop-blur ${style}`}
          >
            <Icon className="mt-0.5 h-4 w-4 shrink-0" />
            <span>{t.message}</span>
          </button>
        );
      })}
    </div>
  );
}
