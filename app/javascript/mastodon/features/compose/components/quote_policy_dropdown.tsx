import { useCallback, useMemo, useState, useRef } from 'react';
import type { FC } from 'react';

import { defineMessages, useIntl } from 'react-intl';

import classNames from 'classnames';

import { setComposeQuotePolicy } from '@/mastodon/actions/compose_typed';
import type { ApiQuotePolicy } from '@/mastodon/api_types/quotes';
import { isQuotePolicy } from '@/mastodon/api_types/quotes';
import type { StatusVisibility } from '@/mastodon/api_types/statuses';
import type { SelectItem } from '@/mastodon/components/dropdown_selector';
import { DropdownSelector } from '@/mastodon/components/dropdown_selector';
import { Icon } from '@/mastodon/components/icon';
import { Popover } from '@/mastodon/components/popover';
import { useAppSelector, useAppDispatch } from '@/mastodon/store';
import FormatQuoteIcon from '@/material-icons/400-24px/format_quote.svg?react';

const messages = defineMessages({
  change_quote_policy: {
    id: 'visibility_modal.quote_label',
    defaultMessage: 'Who can quote'
  },
  anyone: {
    id: 'visibility_modal.quote_public',
    defaultMessage: 'Anyone',
  },
  followers: {
    id: 'visibility_modal.quote_followers',
    defaultMessage: 'Followers only',
  },
  nobody: {
    id: 'visibility_modal.quote_nobody',
    defaultMessage: 'Just me',
  },
});

interface QuotePolicyDropdownProps {
  disabled?: boolean;
}

export const QuotePolicyDropdown: FC<QuotePolicyDropdownProps> = ({ disabled = false }) => {
  const intl = useIntl();
  const dispatch = useAppDispatch();
  const [popoverTarget, setPopoverTarget] = useState<HTMLDivElement | null>(null);
  const previousFocusTargetRef = useRef<HTMLElement>(null);
  const [open, setOpen] = useState(false);

  const quotePolicy = useAppSelector(
    (state) => state.compose.get('quote_policy') as ApiQuotePolicy,
  );

  const visibility = useAppSelector(
    (state) => state.compose.get('privacy') as StatusVisibility,
  );

  const isDisabled = disabled || visibility === 'private' || visibility === 'direct';

  const quotePolicyItems = useMemo<SelectItem<ApiQuotePolicy>[]>(() => [
    {
      value: 'public',
      text: intl.formatMessage(messages.anyone),
      icon: 'quote',
      iconComponent: FormatQuoteIcon,
    },
    {
      value: 'followers',
      text: intl.formatMessage(messages.followers),
      icon: 'quote',
      iconComponent: FormatQuoteIcon,
    },
    {
      value: 'nobody',
      text: intl.formatMessage(messages.nobody),
      icon: 'quote',
      iconComponent: FormatQuoteIcon,
    },
  ], [intl]);

  const currentOption = useMemo(() => {
    if (isDisabled) {
      return quotePolicyItems.find(item => item.value === 'nobody') || quotePolicyItems[2];
    }
    return quotePolicyItems.find(item => item.value === quotePolicy) || quotePolicyItems[0];
  }, [quotePolicyItems, quotePolicy, isDisabled]);

  const handleClose = useCallback(() => {
    if (open && previousFocusTargetRef.current) {
      previousFocusTargetRef.current.focus({ preventScroll: true });
    }
    setOpen(false);
  }, [open]);

  const handleToggle = useCallback(() => {
    if (open) {
      handleClose();
    }
    setOpen((prev) => !prev);
  }, [open, handleClose]);

  const registerPreviousFocusTarget = useCallback(() => {
    if (!open) {
      previousFocusTargetRef.current = document.activeElement as HTMLElement;
    }
  }, [open]);

  const handleButtonKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if ([' ', 'Enter'].includes(e.key)) {
        registerPreviousFocusTarget();
      }
    },
    [registerPreviousFocusTarget],
  );

  const handleChange = useCallback((value: string) => {
    if (isQuotePolicy(value)) {
      dispatch(setComposeQuotePolicy(value));
    }
    handleClose();
  }, [dispatch, handleClose]);

  return (
    <div ref={setPopoverTarget}>
      <button
        type="button"
        title={intl.formatMessage(messages.change_quote_policy)}
        aria-expanded={open}
        onClick={handleToggle}
        onMouseDown={registerPreviousFocusTarget}
        onKeyDown={handleButtonKeyDown}
        disabled={isDisabled}
        className={classNames('dropdown-button', { active: open })}
      >
        <Icon id={currentOption.icon} icon={currentOption.iconComponent} />
        <span className="dropdown-button__label">{currentOption.text}</span>
      </button>

      <Popover
        isOpen={open}
        offset={5}
        reference={popoverTarget}
        onClose={handleClose}
      >
        {({ props, placement }) => (
          <div {...props}>
            <div className={`dropdown-animation privacy-dropdown__dropdown ${placement}`}>
              <DropdownSelector
                items={quotePolicyItems}
                value={isDisabled ? 'nobody' : quotePolicy}
                onClose={handleClose}
                onChange={handleChange}
              />
            </div>
          </div>
        )}
      </Popover>
    </div>
  );
};