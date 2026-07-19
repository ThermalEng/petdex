import Link from "next/link";

import { buttonVariants } from "@/components/ui/button";

type SubmitLinkProps = {
  href: string;
  label: string;
  variant: "desktop" | "mobile";
};

const variantClassName = {
  desktop: buttonVariants({
    variant: "petdex-cta",
    size: "petdex-pill",
    className: "hidden md:inline-flex",
  }),
  mobile: buttonVariants({
    variant: "petdex-cta",
    className: "mt-1 flex rounded-xl px-3 py-2.5 text-sm",
  }),
} as const;

export function SubmitLink({ href, label, variant }: SubmitLinkProps) {
  return (
    <Link href={href} prefetch={false} className={variantClassName[variant]}>
      {label}
    </Link>
  );
}
