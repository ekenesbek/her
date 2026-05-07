import Link from "next/link";

type LegalSection = {
  title: string;
  body: string[];
};

type LegalPageProps = {
  label: string;
  title: string;
  intro: string;
  updated: string;
  active: "terms" | "privacy";
  sections: LegalSection[];
};

export default function LegalPage({
  label,
  title,
  intro,
  updated,
  active,
  sections,
}: LegalPageProps) {
  return (
    <div className="min-h-screen px-5 py-6 sm:px-8 sm:py-8">
      <div className="mx-auto flex w-full max-w-5xl flex-col">
        <header className="flex items-center gap-3 border-b border-[var(--border)] pb-5">
          <Link href="/login" className="flex items-center gap-2.5">
            <span className="grid h-[22px] w-[22px] place-items-center rounded-full bg-[var(--fg)] font-serif text-[11px] italic text-[var(--bg)]">
              h
            </span>
            <span className="font-serif text-[17px] font-medium italic">Her</span>
          </Link>

          <nav className="ml-auto flex items-center gap-2 text-[12px] text-[var(--fg-muted)]">
            <LegalNavLink href="/terms" active={active === "terms"}>
              Terms
            </LegalNavLink>
            <span aria-hidden className="text-[var(--fg-dim)]">
              /
            </span>
            <LegalNavLink href="/privacy" active={active === "privacy"}>
              Privacy
            </LegalNavLink>
          </nav>
        </header>

        <main className="grid gap-10 py-10 lg:grid-cols-[minmax(0,0.82fr)_minmax(0,1.18fr)] lg:gap-14 lg:py-16">
          <section className="lg:sticky lg:top-10 lg:self-start">
            <div className="label-mono">{label}</div>
            <h1 className="mt-5 max-w-[520px] font-serif text-[46px] font-light leading-[0.98] sm:text-[64px]">
              {title}
            </h1>
            <p className="mt-5 max-w-[440px] text-[15px] leading-[1.7] text-[var(--fg-muted)]">
              {intro}
            </p>
            <div className="mt-7 inline-flex rounded-[6px] border border-[var(--border-strong)] px-3 py-2">
              <span className="label-mono text-[9px]">{updated}</span>
            </div>
          </section>

          <article className="divide-y divide-[var(--border)] border-y border-[var(--border)]">
            {sections.map((section, index) => (
              <section key={section.title} className="grid gap-5 py-7 sm:grid-cols-[88px_1fr]">
                <div className="label-mono text-[10px]">
                  {String(index + 1).padStart(2, "0")}
                </div>
                <div>
                  <h2 className="text-[17px] font-medium leading-snug">{section.title}</h2>
                  <div className="mt-3 space-y-3 text-[14px] leading-[1.75] text-[var(--fg-muted)]">
                    {section.body.map((paragraph) => (
                      <p key={paragraph}>{paragraph}</p>
                    ))}
                  </div>
                </div>
              </section>
            ))}
          </article>
        </main>
      </div>
    </div>
  );
}

function LegalNavLink({
  href,
  active,
  children,
}: {
  href: string;
  active: boolean;
  children: React.ReactNode;
}) {
  return (
    <Link
      href={href}
      className="rounded-[5px] px-2 py-1 font-medium"
      style={{
        color: active ? "var(--accent)" : "var(--fg-muted)",
        background: active ? "var(--accent-soft)" : "transparent",
      }}
    >
      {children}
    </Link>
  );
}
