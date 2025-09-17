import { useCallback, useMemo, useState, useRef } from 'react';
import type { FC } from 'react';

import { defineMessages, useIntl } from 'react-intl';

import classNames from 'classnames';

import { changeComposeVisibility } from '@/mastodon/actions/compose_typed';
import type { StatusVisibility } from '@/mastodon/api_types/statuses';
import { isStatusVisibility } from '@/mastodon/api_types/statuses';
import type { SelectItem } from '@/mastodon/components/dropdown_selector';
import { DropdownSelector } from '@/mastodon/components/dropdown_selector';
import { Icon } from '@/mastodon/components/icon';
import { Popover } from '@/mastodon/components/popover';
import { useAppSelector, useAppDispatch } from '@/mastodon/store';
import AlternateEmailIcon from '@/material-icons/400-24px/alternate_email.svg?react';
import LockIcon from '@/material-icons/400-24px/lock.svg?react';
import PublicIcon from '@/material-icons/400-24px/public.svg?react';
import QuietTimeIcon from '@/material-icons/400-24px/quiet_time.svg?react';

import { messages as privacyMessages } from './privacy_dropdown';

const messages = defineMessages({
  change_privacy: { id: 'privacy.change', defaultMessage: 'Change post privacy' },
});

interface VisibilityDropdownProps {
  disabled?: boolean;
  noDirect?: boolean;
}

export const VisibilityDropdown: FC<VisibilityDropdownProps> = ({ disabled = false, noDirect = false }) => {
  const intl = useIntl();
  const dispatch = useAppDispatch();
  const [popoverTarget, setPopoverTarget] = useState<HTMLDivElement | null>(null);
  const previousFocusTargetRef = useRef<HTMLElement>(null);
  const [open, setOpen] = useState(false);

  const visibility = useAppSelector(
    (state) => state.compose.get('privacy') as StatusVisibility,
  );

  const quotedStatusId = useAppSelector(
    (state) => state.compose.get('quoted_status_id') as string | null,
  );

  const statuses = useAppSelector(state => state.statuses);

  const disablePublicVisibilities = useMemo(() => {
    if (!quotedStatusId) return false;

    const status = statuses.get(quotedStatusId);
    if (!status) return false;

    return status.get('visibility') === 'private';
  }, [quotedStatusId, statuses]);

  const visibilityItems = useMemo<SelectItem<StatusVisibility>[]>(() => {
    const items: SelectItem<StatusVisibility>[] = [
      {
        value: 'private',
        text: intl.formatMessage(privacyMessages.private_short),
        meta: intl.formatMessage(privacyMessages.private_long),
        icon: 'lock',
        iconComponent: LockIcon,
      },
    ];

    if (!noDirect) {
      items.push({
        value: 'direct',
        text: intl.formatMessage(privacyMessages.direct_short),
        meta: intl.formatMessage(privacyMessages.direct_long),
        icon: 'at',
        iconComponent: AlternateEmailIcon,
      });
    }

    if (!disablePublicVisibilities) {
      items.unshift(
        {
          value: 'public',
          text: intl.formatMessage(privacyMessages.public_short),
          meta: intl.formatMessage(privacyMessages.public_long),
          icon: 'globe',
          iconComponent: PublicIcon,
        },
        {
          value: 'unlisted',
          text: intl.formatMessage(privacyMessages.unlisted_short),
          meta: intl.formatMessage(privacyMessages.unlisted_long),
          icon: 'unlock',
          iconComponent: QuietTimeIcon,
        },
      );
    }

    return items;
  }, [intl, disablePublicVisibilities, noDirect]);

  const currentOption = useMemo(() => {
    return visibilityItems.find(item => item.value === visibility) || visibilityItems[0];
  }, [visibilityItems, visibility]);

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
    if (isStatusVisibility(value)) {
      dispatch(changeComposeVisibility(value));
    }
    handleClose();
  }, [dispatch, handleClose]);

  return (
    <div ref={setPopoverTarget}>
      <button
        type="button"
        title={intl.formatMessage(messages.change_privacy)}
        aria-expanded={open}
        onClick={handleToggle}
        onMouseDown={registerPreviousFocusTarget}
        onKeyDown={handleButtonKeyDown}
        disabled={disabled}
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
                items={visibilityItems}
                value={visibility}
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