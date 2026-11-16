package db_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/mahmoudalsof/invite-app/server/internal/db"
)

// These tests run against the Docker Compose Postgres with migrations applied (`make test` does both).
// Each test works inside a transaction that is rolled back, so the database is left unchanged.

func newTx(t *testing.T) (*db.Queries, pgx.Tx) {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set; run `make db-up` and `make test`")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, url)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	t.Cleanup(func() {
		tx.Rollback(ctx)
		conn.Close(ctx)
	})
	return db.New(tx), tx
}

// savepoint runs fn in a nested transaction and rolls it back, so an expected error
// does not abort the test's transaction.
func savepoint(t *testing.T, tx pgx.Tx, fn func(q *db.Queries) error) error {
	t.Helper()
	ctx := context.Background()
	sp, err := tx.Begin(ctx)
	if err != nil {
		t.Fatalf("savepoint: %v", err)
	}
	defer sp.Rollback(ctx)
	return fn(db.New(sp))
}

func id() uuid.UUID { return uuid.Must(uuid.NewV7()) }

func ptr[T any](v T) *T { return &v }

type fixture struct {
	account db.Account
	event   db.Event
	men     db.Section
	women   db.Section
}

func setup(t *testing.T, q *db.Queries, packageSize int32) fixture {
	t.Helper()
	ctx := context.Background()
	var f fixture
	var err error
	if f.account, err = q.CreateAccount(ctx, db.CreateAccountParams{ID: id(), Phone: ptr("+966500000001"), Language: "ar"}); err != nil {
		t.Fatal(err)
	}
	if f.event, err = q.CreateEvent(ctx, db.CreateEventParams{ID: id(), OwnerAccountID: f.account.ID, Type: "wedding", Attendance: "both"}); err != nil {
		t.Fatal(err)
	}
	if f.event, err = q.SetEventPackageSize(ctx, db.SetEventPackageSizeParams{ID: f.event.ID, PackageSize: packageSize}); err != nil {
		t.Fatal(err)
	}
	if f.men, err = q.CreateSection(ctx, db.CreateSectionParams{ID: id(), EventID: f.event.ID, Kind: "men"}); err != nil {
		t.Fatal(err)
	}
	if f.women, err = q.CreateSection(ctx, db.CreateSectionParams{ID: id(), EventID: f.event.ID, Kind: "women"}); err != nil {
		t.Fatal(err)
	}
	return f
}

func addGuest(t *testing.T, q *db.Queries, f fixture, section db.Section, phone string, children int32) db.Guest {
	t.Helper()
	g, err := q.CreateGuest(context.Background(), db.CreateGuestParams{
		ID: id(), EventID: f.event.ID, SectionID: section.ID, FullName: "Guest " + phone, Phone: phone, Language: "ar", ChildrenCount: children,
	})
	if err != nil {
		t.Fatalf("add guest %s: %v", phone, err)
	}
	return g
}

func pgCode(err error) (code, constraint string) {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code, pgErr.ConstraintName
	}
	return "", ""
}

func TestPackageLimit(t *testing.T) {
	q, tx := newTx(t)
	ctx := context.Background()
	f := setup(t, q, 2)
	addGuest(t, q, f, f.men, "+1", 0)
	addGuest(t, q, f, f.women, "+2", 0)

	err := savepoint(t, tx, func(q *db.Queries) error {
		_, err := q.CreateGuest(ctx, db.CreateGuestParams{ID: id(), EventID: f.event.ID, SectionID: f.men.ID, FullName: "x", Phone: "+3", Language: "ar"})
		return err
	})
	if code, c := pgCode(err); code != "23514" || c != "guests_package_limit" {
		t.Fatalf("third guest: got %v (code %q, constraint %q), want guests_package_limit", err, code, c)
	}

	tests := []struct {
		name   string
		size   int32
		wantOK bool
	}{
		{"below guest count", 1, false},
		{"equal to guest count", 2, true},
		{"above guest count", 5, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := q.SetEventPackageSize(ctx, db.SetEventPackageSizeParams{ID: f.event.ID, PackageSize: tt.size})
			if tt.wantOK && err != nil {
				t.Fatalf("got %v, want ok", err)
			}
			if !tt.wantOK && !errors.Is(err, pgx.ErrNoRows) {
				t.Fatalf("got %v, want pgx.ErrNoRows", err)
			}
		})
	}

	counts, err := q.CountGuestsBySection(ctx, f.event.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(counts) != 2 || counts[0].Guests != 1 || counts[1].Guests != 1 {
		t.Fatalf("CountGuestsBySection = %+v, want one guest in each section", counts)
	}
}

func TestSetRSVPChildrenLimit(t *testing.T) {
	q, _ := newTx(t)
	ctx := context.Background()
	f := setup(t, q, 10)
	g := addGuest(t, q, f, f.women, "+1", 2)
	inv, err := q.CreateInvitation(ctx, db.CreateInvitationParams{ID: id(), GuestID: g.ID, PublicToken: "tok-" + g.ID.String()})
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name     string
		children int32
		wantOK   bool
	}{
		{"no children", 0, true},
		{"all children", 2, true},
		{"more than invited", 3, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := q.SetRSVP(ctx, db.SetRSVPParams{Rsvp: "accepted", ChildrenAttending: tt.children, PublicToken: inv.PublicToken})
			if !tt.wantOK {
				if !errors.Is(err, pgx.ErrNoRows) {
					t.Fatalf("got %v, want pgx.ErrNoRows", err)
				}
				return
			}
			if err != nil || got.ChildrenAttending != tt.children || got.RsvpAt == nil {
				t.Fatalf("got %+v, %v", got, err)
			}
		})
	}

	page, err := q.GetInvitationPage(ctx, inv.PublicToken)
	if err != nil || page.Guest.ID != g.ID || page.Section.Kind != "women" || page.Event.ID != f.event.ID {
		t.Fatalf("GetInvitationPage = %+v, %v", page, err)
	}
}

func TestCheckInFirstAdmitWins(t *testing.T) {
	q, _ := newTx(t)
	ctx := context.Background()
	f := setup(t, q, 10)
	g := addGuest(t, q, f, f.men, "+1", 0)
	inv, err := q.CreateInvitation(ctx, db.CreateInvitationParams{ID: id(), GuestID: g.ID, PublicToken: "tok-" + g.ID.String()})
	if err != nil {
		t.Fatal(err)
	}
	scan := func(checkInID uuid.UUID, result string) (db.CheckIn, error) {
		return q.InsertCheckIn(ctx, db.InsertCheckInParams{
			ID: checkInID, EventID: f.event.ID, SectionID: f.men.ID, InvitationID: inv.ID,
			DeviceID: "phone-a", ScannedAt: time.Now(), Result: result,
		})
	}

	first := id()
	if _, err := scan(first, "admitted"); err != nil {
		t.Fatalf("first admit: %v", err)
	}
	if _, err := scan(first, "admitted"); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("retried sync: got %v, want pgx.ErrNoRows", err)
	}
	if _, err := scan(id(), "admitted"); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("second admit from another phone: got %v, want pgx.ErrNoRows", err)
	}
	if _, err := scan(id(), "already_used"); err != nil {
		t.Fatalf("already_used scan: %v", err)
	}

	admitted, err := q.GetAdmittedCheckIn(ctx, inv.ID)
	if err != nil || admitted.ID != first {
		t.Fatalf("GetAdmittedCheckIn = %v, %v; want %v", admitted.ID, err, first)
	}
	passes, err := q.ListDoorPasses(ctx, f.men.ID)
	if err != nil || len(passes) != 1 || !passes[0].Admitted {
		t.Fatalf("ListDoorPasses = %+v, %v", passes, err)
	}
	since, err := q.ListCheckInsSince(ctx, db.ListCheckInsSinceParams{SectionID: f.men.ID, Since: time.Now().Add(-time.Minute), MaxRows: 100})
	if err != nil || len(since) != 2 {
		t.Fatalf("ListCheckInsSince = %d rows, %v; want 2", len(since), err)
	}
}

func TestMessageStatusOnlyMovesForward(t *testing.T) {
	q, _ := newTx(t)
	ctx := context.Background()
	f := setup(t, q, 10)
	g := addGuest(t, q, f, f.men, "+1", 0)
	m, err := q.CreateMessage(ctx, db.CreateMessageParams{ID: id(), EventID: f.event.ID, GuestID: &g.ID, Direction: "out", Purpose: "invitation", Language: "ar", Status: "queued"})
	if err != nil {
		t.Fatal(err)
	}
	providerID := "wamid." + m.ID.String()
	if _, err := q.MarkMessageSent(ctx, db.MarkMessageSentParams{ID: m.ID, ProviderMessageID: &providerID}); err != nil {
		t.Fatal(err)
	}

	steps := []struct {
		status  string
		applied bool
	}{
		{"read", true},
		{"delivered", false}, // arrived late
		{"sent", false},
		{"failed", true},
	}
	for _, s := range steps {
		_, err := q.UpdateMessageStatusByProviderID(ctx, db.UpdateMessageStatusByProviderIDParams{Status: s.status, ProviderMessageID: &providerID})
		if s.applied && err != nil {
			t.Fatalf("%s: got %v, want applied", s.status, err)
		}
		if !s.applied && !errors.Is(err, pgx.ErrNoRows) {
			t.Fatalf("%s: got %v, want pgx.ErrNoRows", s.status, err)
		}
	}

	// A failed invitation message is sent again in the next wave.
	toSend, err := q.ListInvitationsToSend(ctx, db.ListInvitationsToSendParams{EventID: f.event.ID, MaxRows: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(toSend) != 0 {
		t.Fatalf("guest has no invitation row yet, want 0 to send, got %d", len(toSend))
	}
	if _, err := q.CreateInvitation(ctx, db.CreateInvitationParams{ID: id(), GuestID: g.ID, PublicToken: "tok-" + g.ID.String()}); err != nil {
		t.Fatal(err)
	}
	if toSend, err = q.ListInvitationsToSend(ctx, db.ListInvitationsToSendParams{EventID: f.event.ID, MaxRows: 10}); err != nil || len(toSend) != 1 {
		t.Fatalf("ListInvitationsToSend = %d rows, %v; want 1 (previous send failed)", len(toSend), err)
	}
}

func TestWalkInDecidedOnce(t *testing.T) {
	q, _ := newTx(t)
	ctx := context.Background()
	f := setup(t, q, 10)
	r, err := q.CreateWalkInRequest(ctx, db.CreateWalkInRequestParams{ID: id(), EventID: f.event.ID, SectionID: f.women.ID, GuestName: "Walk-in"})
	if err != nil {
		t.Fatal(err)
	}
	pending, err := q.ListWalkInRequestsByEvent(ctx, db.ListWalkInRequestsByEventParams{EventID: f.event.ID, Status: ptr("pending")})
	if err != nil || len(pending) != 1 {
		t.Fatalf("pending = %d, %v; want 1", len(pending), err)
	}
	if _, err := q.DecideWalkInRequest(ctx, db.DecideWalkInRequestParams{ID: r.ID, Status: "approved", DecidedBy: &f.account.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := q.DecideWalkInRequest(ctx, db.DecideWalkInRequestParams{ID: r.ID, Status: "declined", DecidedBy: &f.account.ID}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("second decision: got %v, want pgx.ErrNoRows", err)
	}
	all, err := q.ListWalkInRequestsByEvent(ctx, db.ListWalkInRequestsByEventParams{EventID: f.event.ID})
	if err != nil || len(all) != 1 || all[0].Status != "approved" {
		t.Fatalf("all = %+v, %v", all, err)
	}
}

func TestAccountsAndRoles(t *testing.T) {
	q, _ := newTx(t)
	ctx := context.Background()
	f := setup(t, q, 10)

	again, err := q.UpsertAccountByPhone(ctx, db.UpsertAccountByPhoneParams{ID: id(), Phone: f.account.Phone, Language: "en"})
	if err != nil || again.ID != f.account.ID {
		t.Fatalf("UpsertAccountByPhone returned %v, %v; want existing %v", again.ID, err, f.account.ID)
	}

	member, err := q.CreateAccount(ctx, db.CreateAccountParams{ID: id(), Phone: ptr("+966500000002"), Language: "ar"})
	if err != nil {
		t.Fatal(err)
	}
	door, err := q.CreateEventRole(ctx, db.CreateEventRoleParams{ID: id(), EventID: f.event.ID, Role: "door", SectionID: &f.men.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := q.ClaimDoorRole(ctx, db.ClaimDoorRoleParams{ID: door.ID, AccountID: &member.ID}); err != nil {
		t.Fatalf("claim: %v", err)
	}
	if _, err := q.ClaimDoorRole(ctx, db.ClaimDoorRoleParams{ID: door.ID, AccountID: &f.account.ID}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("second claim: got %v, want pgx.ErrNoRows", err)
	}

	events, err := q.ListEventsForAccount(ctx, member.ID)
	if err != nil || len(events) != 1 || events[0].ID != f.event.ID {
		t.Fatalf("door member's events = %+v, %v", events, err)
	}
}
