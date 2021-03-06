#include "../SPDT_general/tree.h"
#include "panel.h"
#include <assert.h>
#include <queue>
#include <stdio.h>
#include <algorithm>
#include <math.h>
#include <time.h>
#include "../SPDT_general/array.h"
#include "../SPDT_general/timing.h"

double COMPRESS_TIME = 0.f;
double SPLIT_TIME = 0.f;
double COMPRESS_COMMUNICATION_TIME = 0.f;
double SPLIT_COMMUNICATION_TIME = 0.f;
long long SIZE = 0 ;

int num_of_features = -1;
int num_of_classes = -1;
int max_bin_size = -1;
int max_num_leaves = -1;

SplitPoint::SplitPoint()
{
    feature_id = -1;
    feature_value = 0;
    entropy = 0;
}

SplitPoint::SplitPoint(int feature_id, float feature_value)
{
    this->feature_id = feature_id;
    this->feature_value = feature_value;
    this->entropy = 0;
}
/*
 * Reture True if the data is larger or equal than the split value
 */
bool SplitPoint::decision_rule(Data &data)
{
    dbg_ensures(entropy >= -EPS);
    dbg_ensures(gain >= -EPS);
    dbg_ensures(feature_id >= 0);
    return data.get_value(feature_id) >= feature_value;
}

// constructor function
TreeNode::TreeNode(int depth, int id)
{
    this->id = id;
    this->depth = depth;
    is_leaf = false;
    label = -1;
    // remove this if you want to keep the previous batch data.
    data_ptr.clear();
    histogram_id = -1;    
    left_node = NULL;
    right_node = NULL;
    entropy = -1.f;
    num_pos_label=0;
    data_size = 0;
    is_leaf = true;
}


void TreeNode::init()
{
    label = -1;
    histogram_id = -1;    
    left_node = NULL;
    right_node = NULL;
    is_leaf = true;
    return;
}

/*
 * Set label for the node as the majority class.
 */
void TreeNode::set_label()
{
    this->is_leaf = true;
    this->label = (this->num_pos_label >= (int)this->data_size / 2) ? POS_LABEL : NEG_LABEL;
}

void TreeNode::printspaces() {
    int i = 0;
    for (i = 0; i < depth * 2; i++) {
        printf(" ");
    }
}

void TreeNode::print() {
    printspaces();
    printf("TreeNode: \n");
    printspaces();
    printf("depth: %d\n", depth);
    printspaces();
    printf("label %d\n", label);
    printspaces();
    printf("is_leaf %d\n", is_leaf);
    printspaces();
    printf("hasLeft: %d\n", left_node != NULL);
    printspaces();
    printf("hasRight: %d\n", right_node != NULL);    
    if (left_node != NULL) {
        left_node->print();
    }

    if (right_node != NULL) {
        right_node->print();
    }
}

void TreeNode::clear(){
    if (left_node != NULL) left_node->clear();
    if (right_node != NULL) right_node->clear();
    data_ptr.clear();
}

DecisionTree::DecisionTree()
{
    this->max_depth = -1;
    this->min_node_size = 1;
    this->depth = 0;
    this->num_leaves = 0;    
    this->cur_depth = 0;
    this->root = NULL;    
    this->min_gain = 1e-3;
    this->num_nodes = 0;
    this->num_unlabled_leaves = 0;

}

DecisionTree::~DecisionTree(){    
    root->clear();
}

/* 
 * Return true if the node should be a leaf.
 * This is determined by the min-node-size, max-depth, max_num_leaves
*/
bool DecisionTree::is_terminated(TreeNode *node)
{
    if (min_node_size != -1 && node->data_size <= min_node_size)
    {
        dbg_printf("Node [%d] terminated: min_node_size=%d >= %d\n", node->id, min_node_size, node->data_size);
        return true;
    }

    if (max_depth != -1 && node->depth >= this->max_depth)
    {
        dbg_printf("Node [%d] terminated: max_depth\n", node->id);
        return true;
    }

    if (max_num_leaves != -1 && this->num_leaves >= max_num_leaves)
    {
        dbg_printf("Node [%d] terminated: max_num_leaves\n", node->id);
        return true;
    }

    if (!node->num_pos_label || node->num_pos_label == (int) node->data_size){
        dbg_assert(node->entropy < EPS);
        dbg_printf("Node [%d] terminated: all samples belong to same class\n",node->id);
        return true; 
    }
    dbg_printf("[%d] num_data=%d, num_pos=%d\n", node->id, node->data_size, node->num_pos_label);
    return false;
}

void DecisionTree::initialize(Dataset &train_data, const int batch_size){
    this->datasetPointer = &train_data;
    root = new TreeNode(0, this->num_nodes++);  
    if (histogram != NULL) {        
        delete[] histogram;
    }
    SIZE  = (long long)max_num_leaves * num_of_features * num_of_classes * ((max_bin_size + 1) * 2 + 1);    
    // printf("Init Root Node [%.4f] MB\n", SIZE * sizeof(float) / 1024.f / 1024.f);
    
    histogram = new float[SIZE];
    memset(histogram, 0, SIZE * sizeof(float));  
    // printf("Init success\n");

}

void DecisionTree::train(Dataset &train_data, const int batch_size)
{
    int hasNext = TRUE;
    initialize(train_data, batch_size);
	while (TRUE) {
		hasNext = train_data.streaming_read_data(batch_size);	
        dbg_printf("Train size (%d, %d, %d)\n", train_data.num_of_data, 
                num_of_features, num_of_classes);
        train_on_batch(train_data);        
		if (!hasNext) break;
	}		
    
	train_data.close_read_data(); 
    return;
}

double DecisionTree::test(Dataset &test_data) {    

    int i = 0;
    int correct_num = 0;
    test_data.streaming_read_data(test_data.num_of_data);

    for (i = 0; i < test_data.num_of_data; i++) {
        assert(navigate(test_data.dataset[i])->label != -1);
        if (navigate(test_data.dataset[i])->label == test_data.dataset[i].label) {
            correct_num++;
        }
    }    
    return (double)correct_num / (double)test_data.num_of_data;
}

/*
 * Calculate the entropy gain = H(Y) - H(Y|X)
 * H(Y|X) needs parameters p(X<a), p(Y=0|X<a), p(Y=0|X>=a)
 * Assuming binary classification problem
 */
void get_gain(TreeNode* node, SplitPoint& split, int feature_id){
    int total_sum = node->data_size;
    dbg_ensures(total_sum > 0);
    double sum_class_0 = get_total_array(node->histogram_id, feature_id, NEG_LABEL);
    double sum_class_1 = get_total_array(node->histogram_id, feature_id, POS_LABEL);
    dbg_assert((sum_class_1 - node->num_pos_label) < EPS);
    double left_sum_class_0 = sum_array(node->histogram_id, feature_id, NEG_LABEL, split.feature_value);
    double right_sum_class_0 = sum_class_0 - left_sum_class_0;
    double left_sum_class_1 = sum_array(node->histogram_id, feature_id, POS_LABEL, split.feature_value);
    double right_sum_class_1 = sum_class_1 - left_sum_class_1;
    double left_sum = left_sum_class_0 + left_sum_class_1;
    double right_sum = right_sum_class_0 + right_sum_class_1;

    double px = (left_sum_class_0 + left_sum_class_1) / (1.0 * total_sum); // p(x<a)
    double py_x0 = (left_sum <= EPS) ? 0.f : left_sum_class_0 / left_sum;                            // p(y=0|x < a)
    double py_x1 = (right_sum <= EPS) ? 0.f : right_sum_class_0 / right_sum;                          // p(y=0|x >= a)
    // printf("id=%d, value=%.f\n", split.feature_id, split.feature_value);
    // printf("left_sum_class_0=%f, left_sum_class_1=%f\n", left_sum_class_0, left_sum_class_1);
    
    // printf("sum_class_1=%f, sum_class_0=%f, right_sum = %f, right_sum_class_0 = %f right_sum_class_1= %f\n", sum_class_1, sum_class_0, right_sum, right_sum_class_0, right_sum_class_1);
    // printf("px = %.f, py_x0 = %f, py_x1 = %f\n", px, py_x0, py_x1);
    dbg_ensures(py_x0 >= -EPS && py_x0 <= 1+EPS);
    dbg_ensures(py_x1 >= -EPS && py_x1 <= 1+EPS);
    dbg_ensures(px >= -EPS && px <= 1+EPS);
    double entropy_left = ((1-py_x0) < EPS || py_x0 < EPS) ? 0 : -py_x0 * log2(py_x0) - (1-py_x0)*log2(1-py_x0);
    double entropy_right = ((1-py_x1) < EPS || py_x1 < EPS) ? 0 : -py_x1 * log2(py_x1) - (1-py_x1)*log2(1-py_x1);
    double H_YX = px * entropy_left + (1-px) * entropy_right;
    double px_prior = sum_class_0 / (sum_class_0 + sum_class_1);
    dbg_ensures(px_prior > 0 && px_prior < 1);
    split.entropy = ((1-px_prior) < EPS || px_prior < EPS) ? 0 : -px_prior * log2(px_prior) - (1-px_prior) * log2(1-px_prior);
    split.gain = split.entropy - H_YX;
    // printf("%f = %f - %f\n", split.gain, split.entropy, H_YX);
    dbg_ensures(split.gain >= -EPS);
}


void DecisionTree::self_check(){
    queue<TreeNode *> q;
    q.push(root);
    int count_leaf=0;
    int count_nodes=0;
    while (!q.empty())
    {
        auto tmp_ptr = q.front();
        q.pop();
        count_nodes++;
        if (tmp_ptr == NULL)
        {
            // should never reach here.
            fprintf(stderr, "ERROR: The tree contains node that have only one child\n");
            exit(-1);
        }
        else if ((tmp_ptr->left_node == NULL) && (tmp_ptr->right_node == NULL))
        {
            dbg_requires(tmp_ptr->is_leaf);
            dbg_requires(tmp_ptr->label == POS_LABEL || tmp_ptr->label == NEG_LABEL);
            count_leaf++;
        }
        else
        {
            dbg_requires(!tmp_ptr->is_leaf);
            dbg_requires(tmp_ptr->label == -1);
            q.push(tmp_ptr->left_node);
            q.push(tmp_ptr->right_node);
        }
    }
    dbg_assert(count_leaf == num_leaves);
    dbg_assert(count_nodes == num_nodes);
    dbg_printf("------------------------------------------------\n");
    dbg_printf("| Num_leaf: %d, num_nodes: %d, max_depth: %d | \n", num_leaves, num_nodes, cur_depth);
    dbg_printf("------------------------------------------------\n");

}


/* 
 * This function reture all the unlabeled leaf nodes in a breadth-first manner.
*/
vector<TreeNode *> DecisionTree::__get_unlabeled(TreeNode *node)
{
    queue<TreeNode *> q;
    q.push(node);
    vector<TreeNode *> ret;
    while (!q.empty())
    {
        auto tmp_ptr = q.front();
        q.pop();
        if (tmp_ptr == NULL)
        {
            // should never reach here.
            fprintf(stderr, "ERROR: The tree contains node that have only one child\n");
            exit(-1);
        }
        else if ((tmp_ptr->left_node == NULL) && (tmp_ptr->right_node == NULL) && tmp_ptr->label < 0)
        {
            ret.push_back(tmp_ptr);
        }
        else
        {
            q.push(tmp_ptr->left_node);
            q.push(tmp_ptr->right_node);
        }
    }
    return ret;
}

/*
 * initialize each leaf as unlabeled.
 */
void DecisionTree::batch_initialize(TreeNode *node)
{
    int feature_id = 0, class_id = 0;

    if (node == NULL)
    {
        // should never reach here.
        fprintf(stderr, "ERROR: The tree contains node that have only one child\n");
        exit(-1);
    }
    else if ((node->left_node == NULL) && (node->right_node == NULL))
    {
       node->init();
    }
    else
    {
        batch_initialize(node->left_node);
        batch_initialize(node->right_node);
    }
    return;
}


/*
 *
 */
TreeNode *DecisionTree::navigate(Data &d)
{
    TreeNode *ptr = this->root;
    while (!ptr->is_leaf)
    {
        dbg_assert(ptr->right_node != NULL && ptr->left_node != NULL);
        ptr = (ptr->split_ptr.decision_rule(d)) ? ptr->right_node : ptr->left_node;
    }
    return ptr;
}

/*
 * This function initialize the histogram for each unlabeled leaf node.
 * Also, potentially, it would free the previous histogram.
 */
void DecisionTree::init_histogram(vector<TreeNode *> &unlabeled_leaf)
{
    int c = 0;      
    assert(unlabeled_leaf.size() <= max_num_leaves);
    
    for (auto &p : unlabeled_leaf)
        p->histogram_id = c++;

    num_unlabled_leaves = c;
    memset(histogram, 0, SIZE * sizeof(float));
}
