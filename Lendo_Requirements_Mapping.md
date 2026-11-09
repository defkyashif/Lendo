# Lendo — съпоставка на изискванията с PostgreSQL

Тази матрица свързва видимите user stories (US-01 до US-20) и бележките от user story map с реалните таблици, ключове, ограничения и изгледи в `01_lendo_schema.sql`.

| User story / изискване | Таблици и реализация в базата |
|---|---|
| US-01 — профил и лична информация | `app_users`, `user_roles`; уникален case-insensitive email индекс, активност и timestamps. |
| US-02 — верификация на акаунт с документ и admin approval | `identity_verifications`; статус `pending/approved/rejected`, reviewer, време на решение; един pending опит на потребител. |
| US-03 — търсене по име/категория | `listings`, `categories`; PostgreSQL generated `search_vector` + GIN индекс. |
| US-04 — търсене по локация | `listing_locations`; индекси по държава/град/пощенски код и приблизителни координати в `public_listing_catalog`. |
| US-05 — календар и свободни дати | `bookings`, `listing_unavailability`, `booking_calendar`; trigger блокира застъпващи се интервали. |
| US-06 — заявка за наем и нотификация към lender | `bookings`, `booking_status_history`, `notifications`; заявката започва със статус `requested`. Изпращането на push е работа на приложението/queue. |
| US-07 — статус и история на резервацията | `bookings`, `booking_status_history`, `notifications`; trigger записва всяка промяна и допуска само валидните преходи между статусите. |
| US-08 — 20% депозит | `listings.deposit_percent` с default 20%; trigger изчислява `bookings.deposit_amount`; `payments` пази security-deposit транзакцията; trigger проверява платеца, сумата и валутата, а при успешен депозит потвърждава booking, създава conversation и известия. |
| US-09 — чат след платен депозит | `conversations`, `messages`, `payments`; database trigger блокира съобщения преди успешно плащане на `security_deposit` и допуска само двете страни. |
| US-10 — оценка от borrower след наем | `reviews`, `public_user_ratings`, `public_listing_ratings`; оценка е възможна само при статус `completed`. |
| US-11 — lender създава обява | `listings`, `categories`, `user_roles`; задължителни полета, draft/published статус и роля `lender`. |
| US-12 — поне 3 снимки | `listing_photos`; обявата не може да се публикува без минимум 3 снимки, а публикувана обява не може да падне под 3. |
| US-13 — цена на час/ден | `listings.rate_amount`, `rate_unit`, `currency`; позитивна цена и валутен формат. |
| US-14 — локация и скриване на точния адрес | `listing_locations`, `public_listing_catalog`; публичният изглед показва град и приблизителни координати, но не точния адрес. API трябва да провери резервацията преди достъп до точния адрес. |
| US-15 — приемане/отказ на заявка | `bookings.status`, `booking_status_history.change_note`; допустими статуси `accepted/rejected`, optional reason се записва като change note. |
| US-16 — нотификация за нова заявка и unread badge | `notifications`; частичен индекс за непрочетени известия. Доставка до 5 секунди изисква application worker/queue. |
| US-17 — lender вижда verified статус и borrower rating | `identity_verifications`, `public_user_ratings`, `reviews`. |
| US-18 — двустранно потвърждение на предаване | `handover_confirmations`; след потвърждение и от двете страни trigger променя booking на `active`. |
| US-19 — сигурно изплащане и дигитална разписка | `payments`, `payout_accounts`, `payouts`; provider token, статуси, `receipt_url`. PDF файлът се генерира и съхранява от приложението. |
| US-20 — lender оценява borrower по Communication и Item Care | `reviews.communication_rating`, `reviews.item_care_rating`; trigger изисква и двете оценки при lender→borrower review; ниска оценка автоматично създава `review_reports` за admin review. |
| Връщане на вещта от двете страни | `handover_confirmations`; след двете return потвърждения статусът става `completed`. |
| Проверка на състоянието на вещта | `condition_reports`, `condition_report_photos`; borrower и lender могат да документират pickup/return състояние. |
| Удължаване на наема | `booking_extensions`; иска се от участник, одобрява се от другия, а одобрението променя `bookings.ends_at` и проверява наличността отново. |
| Help center / contact support | `support_tickets`, `support_ticket_messages`. |
| Community guidelines | `guideline_acceptances`, пази версията на приетите правила. |
| Revenue model — комисионна | `bookings.service_fee_amount` + `payments.payment_type='service_fee'`; сумата се snapshot-ва на резервация. Subscription plans/listing fees не са включени, защото не са дефинирани като избран модел в снимките. |

## Граница на покритието

Таблиците и правилата покриват всички подробно видими US-01…US-20 и бележките от story map. Екранът с Agile Roadmap показва допълнителни групови бройки, но не показва пълните описания и acceptance criteria за останалите елементи. Затова за тях не твърдя, че са реализирани 100%; нови stories могат да добавят таблици или полета, без да се налага да се пренаписва целият модел.
