
#import "WMFSearchViewController.h"
#import "RecentSearchesViewController.h"
#import "WMFArticleListCollectionViewController.h"

#import "WMFSearchFetcher.h"
#import "WMFSearchResults.h"

#import "SearchDidYouMeanButton.h"
#import <Masonry/Masonry.h>

#import "Wikipedia-Swift.h"
#import "PromiseKit.h"

static NSUInteger const kWMFMinResultsBeforeAutoFullTextSearch = 12;

@interface WMFSearchViewController ()<WMFRecentSearchesViewControllerDelegate>

@property (nonatomic, strong) RecentSearchesViewController* recentSearchesViewController;
@property (nonatomic, strong) WMFArticleListCollectionViewController* resultsListController;

@property (strong, nonatomic) IBOutlet UISearchBar* searchBar;
@property (strong, nonatomic) IBOutlet UIButton* searchSuggestionButton;
@property (strong, nonatomic) IBOutlet UIView* resultsListContainerView;
@property (strong, nonatomic) IBOutlet UIView* recentSearchesContainerView;

@property (nonatomic, strong) WMFSearchFetcher* fetcher;

@property (nonatomic, assign, readwrite) WMFSearchState state;

@property (nonatomic, strong) MASConstraint* suggestionButtonVisibleConstraint;
@property (nonatomic, strong) MASConstraint* suggestionButtonHiddenConstraint;

@end

@implementation WMFSearchViewController

- (void)setUserDataStore:(MWKUserDataStore* __nonnull)userDataStore {
    [self unobserveSavedPages];
    _userDataStore                        = userDataStore;
    self.resultsListController.savedPages = _userDataStore.savedPageList;
    [self observeSavedPages];
}

- (void)setDataStore:(MWKDataStore* __nonnull)dataStore {
    _dataStore                           = dataStore;
    self.resultsListController.dataStore = _dataStore;
}

- (NSString*)currentSearchTerm {
    return [(WMFSearchResults*)self.resultsListController.dataSource searchTerm];
}

- (NSString*)searchSuggestion {
    return [(WMFSearchResults*)self.resultsListController.dataSource searchSuggestion];
}

- (void)updateSearchStateAndNotifyDelegate:(WMFSearchState)state {
    if (self.state == state) {
        return;
    }

    self.state = state;

    [self.delegate searchController:self searchStateDidChange:self.state];
}

- (void)updateRecentSearchesVisibility {
    if ([self.searchBar.text length] == 0 && [self.searchBar isFirstResponder] && self.recentSearchesViewController.recentSearchesItemCount > 0) {
        [self.recentSearchesContainerView setHidden:NO];
    } else {
        [self.recentSearchesContainerView setHidden:YES];
    }
}

#pragma mark - DataSource KVO

- (void)observeSavedPages {
    [self.KVOController observe:self.userDataStore.savedPageList keyPath:WMF_SAFE_KEYPATH(self.userDataStore.savedPageList, entries) options:0 block:^(id observer, id object, NSDictionary* change) {
        [self.resultsListController refreshVisibleCells];
    }];
}

- (void)unobserveSavedPages {
    [self.KVOController unobserve:self.userDataStore.savedPageList];
}

#pragma mark - UIViewController

- (void)viewDidLoad {
    [super viewDidLoad];
//    self.resultsListController.delegate                           = self;
    self.resultsListController.collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self updateUIWithResults:nil];
}

- (void)prepareForSegue:(UIStoryboardSegue*)segue sender:(id)sender {
    if ([segue.destinationViewController isKindOfClass:[WMFArticleListCollectionViewController class]]) {
        self.resultsListController = segue.destinationViewController;
    }
    if ([segue.destinationViewController isKindOfClass:[RecentSearchesViewController class]]) {
        self.recentSearchesViewController          = segue.destinationViewController;
        self.recentSearchesViewController.delegate = self;
    }
}

#pragma mark - UISearchBarDelegate

- (void)searchBarTextDidBeginEditing:(UISearchBar*)searchBar {
    [self updateSearchStateAndNotifyDelegate:WMFSearchStateActive];

    [self updateRecentSearchesVisibility];

    [self.searchBar setShowsCancelButton:YES animated:YES];

    self.fetcher = [[WMFSearchFetcher alloc] initWithSearchSite:self.searchSite dataStore:self.dataStore];

    if (![[self currentSearchTerm] isEqualToString:self.searchBar.text]) {
        [self searchForSearchTerm:self.searchBar.text];
    }
}

- (void)searchBar:(UISearchBar*)searchBar textDidChange:(NSString*)searchText {
    [self updateRecentSearchesVisibility];

    if ([searchText length] == 0) {
        self.resultsListController.dataSource = nil;
    }

    dispatchOnMainQueueAfterDelayInSeconds(0.4, ^{
        if ([searchText isEqualToString:self.searchBar.text]) {
            [self searchForSearchTerm:searchText];
        }
    });
}

- (void)searchBarTextDidEndEditing:(UISearchBar*)searchBar {
    [self updateRecentSearchesVisibility];
}

- (void)searchBarSearchButtonClicked:(UISearchBar*)searchBar {
    [self updateRecentSearchesVisibility];
}

- (void)searchBarCancelButtonClicked:(UISearchBar*)searchBar {
    [self updateRecentSearchesVisibility];
    [self updateSearchStateAndNotifyDelegate:WMFSearchStateInactive];
    self.searchBar.text                   = nil;
    self.resultsListController.dataSource = nil;
    [self.searchBar setShowsCancelButton:NO animated:YES];
    [self.searchBar resignFirstResponder];
}

#pragma mark - Search

- (void)searchForSearchTerm:(NSString*)searchTerm {
    dispatch_promise(^{
        return [self.fetcher searchArticleTitlesForSearchTerm:searchTerm];
    }).then((id) ^ (WMFSearchResults * results){
        [UIView animateWithDuration:0.25 animations:^{
            [self updateUIWithResults:results];
        }];

        self.resultsListController.dataSource = results;

        if ([results.articles count] < kWMFMinResultsBeforeAutoFullTextSearch) {
            return [self.fetcher searchFullArticleTextForSearchTerm:searchTerm appendToPreviousResults:results];
        }

        return [AnyPromise promiseWithValue:results];
    }).then(^(WMFSearchResults* results){
        if ([searchTerm isEqualToString:results.searchTerm]) {
            self.resultsListController.dataSource = results;
            [self.recentSearchesViewController saveTerm:searchTerm forDomain:self.fetcher.searchSite.domain type:SEARCH_TYPE_TITLES];
        }
    }).catch(^(NSError* error){
        NSLog(@"%@", [error description]);
    });
}

- (void)updateUIWithResults:(WMFSearchResults*)results {
    self.title = results.searchTerm;
    [self updateSearchButtonWithResults:results.searchSuggestion];
}

- (void)updateSearchButtonWithResults:(NSString*)searchSuggestion {
    if ([searchSuggestion length]) {
        [self.searchSuggestionButton setTitle:[NSString stringWithFormat:@"%@:%@", MWLocalizedString(@"search-did-you-mean", nil), searchSuggestion] forState:UIControlStateNormal];

        if (!self.suggestionButtonVisibleConstraint) {
            [self.suggestionButtonHiddenConstraint uninstall];
            self.suggestionButtonHiddenConstraint = nil;
            [self.resultsListContainerView mas_makeConstraints:^(MASConstraintMaker* make) {
                self.suggestionButtonVisibleConstraint = make.top.equalTo(self.searchSuggestionButton.mas_bottom).with.offset(6.0);
            }];
            [self.view layoutIfNeeded];
        }
    } else {
        [self.searchSuggestionButton setTitle:nil forState:UIControlStateNormal];

        if (!self.suggestionButtonHiddenConstraint) {
            [self.suggestionButtonVisibleConstraint uninstall];
            self.suggestionButtonVisibleConstraint = nil;
            [self.resultsListContainerView mas_makeConstraints:^(MASConstraintMaker* make) {
                self.suggestionButtonHiddenConstraint = make.top.equalTo(self.searchBar.mas_bottom);
            }];
            [self.view layoutIfNeeded];
        }
    }
}

#pragma mark - WMFRecentSearchesViewControllerDelegate

- (void)recentSearchController:(RecentSearchesViewController*)controller didSelectSearchTerm:(NSString*)searchTerm {
    self.searchBar.text = searchTerm;
    [self searchForSearchTerm:searchTerm];
    [self updateRecentSearchesVisibility];
}

#pragma mark - Actions

- (IBAction)searchForSuggestion:(id)sender {
    self.searchBar.text = [self searchSuggestion];
    [UIView animateWithDuration:0.25 animations:^{
        [self updateSearchButtonWithResults:nil];
    }];

    [self searchForSearchTerm:self.searchBar.text];
}

@end
