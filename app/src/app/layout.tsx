import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import Link from "next/link";
import { getCurrentUser } from "@/lib/auth";
import LogoutButton from "./logout-button";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "meta — твои персональные агенты",
  description: "Создавай агентов с доступом к браузеру и сервисам.",
};

export default async function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const user = await getCurrentUser();

  return (
    <html lang="ru" className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}>
      <body className="min-h-screen flex flex-col">
        <header className="border-b border-[var(--border)] px-6 py-4 flex items-center justify-between">
          <Link href="/" className="flex items-center gap-2 font-semibold tracking-tight">
            <span className="w-6 h-6 rounded-md bg-[var(--accent)] grid place-items-center text-black text-sm">m</span>
            <span>meta</span>
          </Link>
          <nav className="flex items-center gap-4 text-sm text-[var(--fg-muted)]">
            {user ? (
              <>
                <Link href="/dashboard" className="hover:text-[var(--fg)]">Агенты</Link>
                <Link href="/web-mcp" className="hover:text-[var(--fg)]">Web MCP</Link>
                <Link href="/onboarding" className="btn btn-primary !py-1.5 !px-3 text-xs">+ Новый</Link>
                <span className="hidden md:block text-xs text-[var(--fg-dim)]">{user.email}</span>
                <LogoutButton />
              </>
            ) : (
              <Link href="/login" className="btn btn-primary !py-1.5 !px-3 text-xs">Войти</Link>
            )}
          </nav>
        </header>
        <main className="flex-1 flex flex-col">{children}</main>
      </body>
    </html>
  );
}
