import { useCallback, useMemo, useState, useRef } from 'react';
import type { FC } from 'react';

import { defineMessages, useIntl } from 'react-intl';

import classNames from 'classnames';
import Overlay from 'react-overlays/Overlay';

import { setComposeQuotePolicy } from '@/mastodon/actions/compose_typed';
import type { ApiQuotePolicy } from '@/mastodon/api_types/quotes';
import { isQuotePolicy } from '@/mastodon/api_types/quotes';
import type { StatusVisibility } from '@/mastodon/api_types/statuses';
import type { SelectItem } from '@/mastodon/components/dropdown_selector';
import { DropdownSelector } from '@/mastodon/components/dropdown_selector';
import { Icon } from '@/mastodon/components/icon';
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
  const targetRef = useRef<HTMLDivElement>(null);
  const activeElementRef = useRef<HTMLElement | null>(null);
  const [open, setOpen] = useState(false);
  const [placement, setPlacement] = useState('bottom');

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

  const handleMouseDown = useCallback(() => {
    if (!open && document.activeElement instanceof HTMLElement) {
      activeElementRef.current = document.activeElement;
    }
  }, [open]);

  const handleToggle = useCallback(() => {
    if (open && activeElementRef.current) {
      activeElementRef.current.focus({ preventScroll: true });
    }
    if (!isDisabled) {
      setOpen(!open);
    }
  }, [open, isDisabled]);

  const handleClose = useCallback(() => {
    if (open && activeElementRef.current) {
      activeElementRef.current.focus({ preventScroll: true });
    }
    setOpen(false);
  }, [open]);

  const handleChange = useCallback((value: string) => {
    if (isQuotePolicy(value)) {
      dispatch(setComposeQuotePolicy(value));
    }
    handleClose();
  }, [dispatch, handleClose]);

  const handleOverlayEnter = useCallback((state: any) => {
    setPlacement(state.placement);
  }, []);

  const findTarget = useCallback(() => {
    return targetRef.current;
  }, []);

  return (
    <div ref={targetRef}>
      <button
        type="button"
        title={intl.formatMessage(messages.change_quote_policy)}
        aria-expanded={open}
        onClick={handleToggle}
        onMouseDown={handleMouseDown}
        disabled={isDisabled}
        className={classNames('dropdown-button', { active: open })}
      >
        <Icon id={currentOption.icon} icon={currentOption.iconComponent} />
        <span className="dropdown-button__label">{currentOption.text}</span>
      </button>

      <Overlay
        show={open}
        offset={[5, 5]}
        placement={placement}
        flip
        target={findTarget}
        popperConfig={{ strategy: 'fixed', onFirstUpdate: handleOverlayEnter }}
      >
        {({ props }) => (
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
      </Overlay>
    </div>
  );
};