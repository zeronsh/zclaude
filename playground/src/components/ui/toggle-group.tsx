import { ToggleGroup as ToggleGroupPrimitive } from 'radix-ui';
import * as React from 'react';
import { cn } from '@/lib/utils';

function ToggleGroup({ className, ...props }: React.ComponentProps<typeof ToggleGroupPrimitive.Root>) {
  return <ToggleGroupPrimitive.Root data-slot="toggle-group" className={cn('flex w-fit items-center rounded-md border shadow-xs', className)} {...props} />;
}

function ToggleGroupItem({ className, ...props }: React.ComponentProps<typeof ToggleGroupPrimitive.Item>) {
  return (
    <ToggleGroupPrimitive.Item
      data-slot="toggle-group-item"
      className={cn(
        'inline-flex h-7 items-center justify-center px-2.5 text-xs font-medium text-muted-foreground transition-colors first:rounded-l-md last:rounded-r-md hover:bg-muted hover:text-foreground data-[state=on]:bg-accent data-[state=on]:text-accent-foreground outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:opacity-50',
        className,
      )}
      {...props}
    />
  );
}

export { ToggleGroup, ToggleGroupItem };
